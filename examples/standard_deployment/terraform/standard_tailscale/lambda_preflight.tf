# Tailscale preflight-check Lambda (read-only)
#
# Validates the tailnet before a cluster deploy (invoked as a data source from
# ex_basic; a precondition there BLOCKS the apply on a real misconfig). Read-only:
# uses the dedicated read-only OAuth client (aws_ssm_parameter.tailscale_readonly_oauth).
# Dispatches on the "check" payload field: "tags" (required tag owners exist) or
# "dns" (MagicDNS enabled). Fails open on API errors so a hiccup can't wedge apply.

data "archive_file" "preflight" {
  type        = "zip"
  source_file = "${path.module}/data/preflight.py"
  output_path = "${path.module}/data/preflight.zip"
}

# --- Execution role ---------------------------------------------------------
data "aws_iam_policy_document" "preflight_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "preflight" {
  name               = "tailscale-preflight-${var.nickname}"
  assume_role_policy = data.aws_iam_policy_document.preflight_assume.json
}

resource "aws_iam_role_policy_attachment" "preflight_logs" {
  role       = aws_iam_role.preflight.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Read + decrypt ONLY the read-only OAuth SecureString.
data "aws_iam_policy_document" "preflight_inline" {
  statement {
    sid       = "ReadOAuthParam"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.tailscale_readonly_oauth.arn]
  }
  statement {
    sid       = "DecryptOAuthParam"
    actions   = ["kms:Decrypt"]
    resources = ["*"] # default aws/ssm key; scope to a CMK if you use one
  }

  dynamic "statement" {
    for_each = var.lambda_enable_xray_tracing ? [1] : []
    content {
      sid       = "XRayTracing"
      actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
      resources = ["*"] # X-Ray does not support resource-level permissions
    }
  }
}

resource "aws_iam_role_policy" "preflight_inline" {
  name   = "preflight-oauth-read"
  role   = aws_iam_role.preflight.id
  policy = data.aws_iam_policy_document.preflight_inline.json
}

# --- Function ---------------------------------------------------------------
resource "aws_cloudwatch_log_group" "preflight" {
  name              = "/aws/lambda/tailscale-preflight-${var.nickname}"
  retention_in_days = var.lambda_log_retention_days

  # checkov:skip=CKV_AWS_338:Retention is a dev-configurable cost/audit tradeoff (var.lambda_log_retention_days); default 180d.
  # checkov:skip=CKV_AWS_158:Log-group KMS CMK adds ~$1/month; default CloudWatch encryption is sufficient here.
}

resource "aws_lambda_function" "preflight" {
  function_name = "tailscale-preflight-${var.nickname}"
  description   = "Validates the tailnet (tags/DNS) before a cluster deploy (read-only)"
  role          = aws_iam_role.preflight.arn
  runtime       = "python3.13"
  handler       = "preflight.handler"
  timeout       = 30

  filename         = data.archive_file.preflight.output_path
  source_code_hash = data.archive_file.preflight.output_base64sha256

  reserved_concurrent_executions = 1

  environment {
    variables = {
      TS_OAUTH_SSM_PARAM = aws_ssm_parameter.tailscale_readonly_oauth.name
    }
  }

  tracing_config {
    mode = var.lambda_enable_xray_tracing ? "Active" : "PassThrough"
  }

  depends_on = [aws_cloudwatch_log_group.preflight]

  # checkov:skip=CKV_AWS_117:Needs public egress to the Tailscale API; not VPC-bound.
  # checkov:skip=CKV_AWS_116:Synchronous data-source invoke; no async path, so no dead-letter queue.
  # checkov:skip=CKV_AWS_272:Code signing is overkill for this in-repo single-file function.
  # checkov:skip=CKV_AWS_173:Only non-secret env var (an SSM parameter NAME, not a secret).
  # checkov:skip=CKV_AWS_50:X-Ray tracing is a dev-configurable option (var.lambda_enable_xray_tracing).
}

# --- Handoff to ex_basic ----------------------------------------------------
# ex_basic reads this ARN and invokes the function as a data source at plan time,
# then a precondition blocks the apply if a check returns ok=false.
resource "aws_ssm_parameter" "preflight_lambda_arn" {
  name        = "/tailscale-standalone/${var.nickname}/preflight_lambda_arn"
  description = "ARN of the Tailscale preflight Lambda (invoked by ex_basic to gate the deploy)"
  type        = "String"
  value       = aws_lambda_function.preflight.arn

  tags = {
    Nickname = var.nickname
  }
}
