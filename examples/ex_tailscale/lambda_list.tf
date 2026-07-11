# Tailscale device-list Lambda (read-only)
#
# Lists the tailnet devices carrying our managed tags. Read-only: it uses the
# dedicated read-only OAuth client (aws_ssm_parameter.tailscale_readonly_oauth),
# so its token cannot delete anything. Invoke ad-hoc for debugging, e.g.:
#   aws lambda invoke --function-name tailscale-list-<nickname> \
#     --payload '{}' /dev/stdout

data "archive_file" "list" {
  type        = "zip"
  source_file = "${path.module}/data/list_devices.py"
  output_path = "${path.module}/data/list_devices.zip"
}

# --- Execution role ---------------------------------------------------------
data "aws_iam_policy_document" "list_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "list" {
  name               = "tailscale-list-${var.nickname}"
  assume_role_policy = data.aws_iam_policy_document.list_assume.json
}

resource "aws_iam_role_policy_attachment" "list_logs" {
  role       = aws_iam_role.list.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Read + decrypt ONLY the read-only OAuth SecureString.
data "aws_iam_policy_document" "list_inline" {
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

resource "aws_iam_role_policy" "list_inline" {
  name   = "list-oauth-read"
  role   = aws_iam_role.list.id
  policy = data.aws_iam_policy_document.list_inline.json
}

# --- Function ---------------------------------------------------------------
resource "aws_cloudwatch_log_group" "list" {
  name              = "/aws/lambda/tailscale-list-${var.nickname}"
  retention_in_days = var.lambda_log_retention_days

  # checkov:skip=CKV_AWS_338:Retention is a dev-configurable cost/audit tradeoff (var.lambda_log_retention_days); default 180d.
  # checkov:skip=CKV_AWS_158:Log-group KMS CMK adds ~$1/month; default CloudWatch encryption is sufficient here.
}

resource "aws_lambda_function" "list" {
  function_name = "tailscale-list-${var.nickname}"
  description   = "Lists this deployment's managed Tailscale devices (read-only)"
  role          = aws_iam_role.list.arn
  runtime       = "python3.13"
  handler       = "list_devices.handler"
  timeout       = 30

  filename         = data.archive_file.list.output_path
  source_code_hash = data.archive_file.list.output_base64sha256

  reserved_concurrent_executions = 1

  environment {
    variables = {
      TS_OAUTH_SSM_PARAM = aws_ssm_parameter.tailscale_readonly_oauth.name
    }
  }

  tracing_config {
    mode = var.lambda_enable_xray_tracing ? "Active" : "PassThrough"
  }

  depends_on = [aws_cloudwatch_log_group.list]

  # checkov:skip=CKV_AWS_117:Needs public egress to the Tailscale API; not VPC-bound.
  # checkov:skip=CKV_AWS_116:Read-only utility; no async invocation, so no dead-letter queue.
  # checkov:skip=CKV_AWS_272:Code signing is overkill for this in-repo single-file function.
  # checkov:skip=CKV_AWS_173:Only non-secret env var (an SSM parameter NAME, not a secret).
  # checkov:skip=CKV_AWS_50:X-Ray tracing is a dev-configurable option (var.lambda_enable_xray_tracing).
}
