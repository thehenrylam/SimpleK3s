# Tailscale device-cleanup Lambda
#
# Deletes this cluster's tailnet devices when the cluster (examples/ex_basic) is
# destroyed. It lives HERE — in the durable Tailscale root — so it always exists
# when the cluster root invokes it; the cluster root only holds the invocation
# (see aws_lambda_invocation in examples/ex_basic). The function reuses the
# operator OAuth client stored in aws_ssm_parameter.tailscale_oauth (which must
# have "devices" write scope) to call the Tailscale API.

# Package the single-file handler (stdlib only: boto3 + urllib ship in the runtime).
data "archive_file" "cleanup" {
  type        = "zip"
  source_file = "${path.module}/data/cleanup_devices.py"
  output_path = "${path.module}/data/cleanup_devices.zip"
}

# --- Execution role ---------------------------------------------------------
data "aws_iam_policy_document" "cleanup_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cleanup" {
  name               = "tailscale-cleanup-${var.nickname}"
  assume_role_policy = data.aws_iam_policy_document.cleanup_assume.json
}

# CloudWatch Logs (basic execution role).
resource "aws_iam_role_policy_attachment" "cleanup_logs" {
  role       = aws_iam_role.cleanup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Read + decrypt the OAuth SecureString; emit X-Ray segments (tracing enabled).
data "aws_iam_policy_document" "cleanup_inline" {
  statement {
    sid       = "ReadOAuthParam"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.tailscale_oauth.arn]
  }
  statement {
    sid       = "DecryptOAuthParam"
    actions   = ["kms:Decrypt"]
    resources = ["*"] # default aws/ssm key; scope to a CMK if you use one
  }

  # Only granted when X-Ray tracing is enabled (least privilege).
  dynamic "statement" {
    for_each = var.lambda_enable_xray_tracing ? [1] : []
    content {
      sid       = "XRayTracing"
      actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
      resources = ["*"] # X-Ray does not support resource-level permissions
    }
  }
}

resource "aws_iam_role_policy" "cleanup_inline" {
  name   = "cleanup-oauth-read"
  role   = aws_iam_role.cleanup.id
  policy = data.aws_iam_policy_document.cleanup_inline.json
}

# --- Function ---------------------------------------------------------------
# Explicit log group so retention is set (default would be never-expire).
resource "aws_cloudwatch_log_group" "cleanup" {
  name              = "/aws/lambda/tailscale-cleanup-${var.nickname}"
  retention_in_days = var.lambda_log_retention_days

  # checkov:skip=CKV_AWS_338:Retention is a dev-configurable cost/audit tradeoff (var.lambda_log_retention_days); default 180d.
  # checkov:skip=CKV_AWS_158:Log-group KMS CMK adds ~$1/month; default CloudWatch encryption is sufficient here.
}

resource "aws_lambda_function" "cleanup" {
  function_name = "tailscale-cleanup-${var.nickname}"
  description   = "Deletes this cluster's Tailscale devices on cluster destroy"
  role          = aws_iam_role.cleanup.arn
  runtime       = "python3.13"
  handler       = "cleanup_devices.handler"
  timeout       = 30

  filename         = data.archive_file.cleanup.output_path
  source_code_hash = data.archive_file.cleanup.output_base64sha256

  # Cleanup runs rarely and must never fan out; cap concurrency.
  reserved_concurrent_executions = 1

  environment {
    variables = {
      # Tailnet-level (same for every cluster on this tailnet). Cluster-level
      # values (hostname_prefix, tags) arrive in the invocation payload.
      TS_OAUTH_SSM_PARAM = aws_ssm_parameter.tailscale_oauth.name
    }
  }

  tracing_config {
    mode = var.lambda_enable_xray_tracing ? "Active" : "PassThrough"
  }

  depends_on = [aws_cloudwatch_log_group.cleanup]

  # checkov:skip=CKV_AWS_117:Needs public egress to the Tailscale API; not VPC-bound.
  # checkov:skip=CKV_AWS_116:Synchronous Terraform invoke; a dead-letter queue adds nothing.
  # checkov:skip=CKV_AWS_272:Code signing is overkill for this in-repo single-file function.
  # checkov:skip=CKV_AWS_173:Only non-secret env var (an SSM parameter NAME, not a secret).
  # checkov:skip=CKV_AWS_50:X-Ray tracing is a dev-configurable option (var.lambda_enable_xray_tracing).
}

# --- Handoff to ex_basic ----------------------------------------------------
# Publish the function ARN via SSM (same publish -> data-read convention used for
# oauth_config / magic_dns_name). ex_basic reads this to wire its invocation.
resource "aws_ssm_parameter" "cleanup_lambda_arn" {
  name        = "/tailscale-standalone/${var.nickname}/cleanup_lambda_arn"
  description = "ARN of the Tailscale device-cleanup Lambda (invoked on cluster destroy)"
  type        = "String"
  value       = aws_lambda_function.cleanup.arn

  tags = {
    Nickname = var.nickname
  }
}
