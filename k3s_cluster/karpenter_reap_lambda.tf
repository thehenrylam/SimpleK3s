# Karpenter node reaper (destroy-time). See issue #128.
#
# Karpenter's nodes are created in-cluster, so they are not in Terraform state and
# nothing reaps them; their ENIs then block the security group and VPC delete.

# Package the single-file handler (boto3 ships in the Lambda Python runtime).
data "archive_file" "karpenter_reap" {
  type        = "zip"
  source_file = "${path.module}/data/reap_karpenter_nodes.py"
  output_path = "${path.module}/data/reap_karpenter_nodes.zip"
}

# --- Execution role ---------------------------------------------------------
data "aws_iam_policy_document" "karpenter_reap_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter_reap" {
  name               = "karpenter-reap-${var.nickname}"
  assume_role_policy = data.aws_iam_policy_document.karpenter_reap_assume.json
}

resource "aws_iam_role_policy_attachment" "karpenter_reap_logs" {
  role       = aws_iam_role.karpenter_reap.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# The safety control that does not depend on the handler being correct: AWS itself
# refuses unless an instance carries BOTH this cluster's Nickname AND the Karpenter
# lifecycle tag. Control-plane and agent nodes carry Nickname but never the
# lifecycle tag, so this role cannot reach them.
data "aws_iam_policy_document" "karpenter_reap_inline" {
  statement {
    sid     = "DescribeInstances"
    actions = ["ec2:DescribeInstances"]
    # ec2:Describe* does not support resource-level permissions or tag conditions.
    # Read-only, so the blast radius of the wildcard is disclosure of instance
    # metadata the deployer can already read.
    resources = ["*"]
  }

  statement {
    sid       = "TerminateKarpenterNodesOnly"
    actions   = ["ec2:TerminateInstances"]
    resources = ["arn:aws:ec2:${var.aws_region}:*:instance/*"]

    # Multiple condition blocks are ANDed, so BOTH tags must match.
    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Nickname"
      values   = [var.nickname]
    }
    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/simplek3s.io/lifecycle"
      values   = ["karpenter"]
    }
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

resource "aws_iam_role_policy" "karpenter_reap_inline" {
  name   = "karpenter-reap-ec2"
  role   = aws_iam_role.karpenter_reap.id
  policy = data.aws_iam_policy_document.karpenter_reap_inline.json
}

# --- Function ---------------------------------------------------------------
# Explicit log group so retention is set (default would be never-expire).
resource "aws_cloudwatch_log_group" "karpenter_reap" {
  name              = "/aws/lambda/karpenter-reap-${var.nickname}"
  retention_in_days = var.lambda_log_retention_days

  # checkov:skip=CKV_AWS_338:Retention is a dev-configurable cost/audit tradeoff (var.lambda_log_retention_days); default 180d.
  # checkov:skip=CKV_AWS_158:Log-group KMS CMK adds ~$1/month; default CloudWatch encryption is sufficient here.
}

resource "aws_lambda_function" "karpenter_reap" {
  function_name = "karpenter-reap-${var.nickname}"
  description   = "Terminates this cluster's Karpenter-provisioned nodes on cluster destroy"
  role          = aws_iam_role.karpenter_reap.arn
  runtime       = "python3.13"
  handler       = "reap_karpenter_nodes.handler"

  # Graviton: ~20% cheaper per GB-second, and consistent with the ARM cluster.
  architectures = ["arm64"]

  # Worst case is 3 x 15s kill rounds; 900s is far more than needed.
  timeout = 900

  filename         = data.archive_file.karpenter_reap.output_path
  source_code_hash = data.archive_file.karpenter_reap.output_base64sha256

  # Runs once per teardown and must never fan out.
  reserved_concurrent_executions = 1

  tracing_config {
    mode = var.lambda_enable_xray_tracing ? "Active" : "PassThrough"
  }

  depends_on = [aws_cloudwatch_log_group.karpenter_reap]

  # NOT VPC-attached on purpose: a Lambda with ENIs in this VPC would itself
  # become a DependencyViolation blocking the teardown it exists to unblock.
  # checkov:skip=CKV_AWS_117:Must stay outside the VPC it is tearing down; see above.
  # checkov:skip=CKV_AWS_116:Synchronous Terraform invoke; a dead-letter queue adds nothing.
  # checkov:skip=CKV_AWS_272:Code signing is overkill for this in-repo single-file function.
  # checkov:skip=CKV_AWS_50:X-Ray tracing is a dev-configurable option (var.lambda_enable_xray_tracing).
}

# --- Destroy-time invocation -------------------------------------------------
# lifecycle_scope = "CRUD" invokes the function on EVERY lifecycle event, not just
# destroy: a fresh apply fires it with tf.action = "create". The handler no-ops on
# anything that is not a delete, and the IAM conditions above bound it regardless.
# (`tofu plan` and `tofu init` never invoke it -- this is a resource, not a data
# source; only the data-source form runs at plan time.)
#
# ORDERING. The reap must land after the cluster's instances are gone (so
# Karpenter cannot replace what is killed) and before the security group those
# nodes attach to is deleted. Destroy runs in reverse dependency order, so:
#
#   - the instances depend on this invocation (declared in cluster_ec2.tf), which
#     puts them ahead of it; instance destroy does not return until 'terminated',
#     so Karpenter is definitively gone before this fires;
#   - this invocation depends on sg_instances, which puts it ahead of the group.
#
#   => instances -> reap -> security group
#
# Expressing this is why the Lambda lives in the module rather than the cluster
# root: both endpoints are module-internal, so no dependency declared outside can
# order between them. Two root-level orderings were tried on live teardowns and
# both failed -- ahead of the cluster, Karpenter replaced the reaped node; behind
# it, the security group deadlocked the teardown.
#
# The IAM entries are in depends_on because the function depends on the ROLE but
# nothing tied it to the role's POLICY, so Terraform deleted TerminateInstances
# while the invocation still needed it.
#
# NOTE: whoever runs `tofu destroy` needs lambda:InvokeFunction on this function.
resource "aws_lambda_invocation" "karpenter_reap" {
  function_name   = aws_lambda_function.karpenter_reap.function_name
  lifecycle_scope = "CRUD"

  input = jsonencode({
    nickname = var.nickname
    region   = var.aws_region
  })

  depends_on = [
    aws_security_group.sg_instances,
    aws_iam_role_policy.karpenter_reap_inline,
    aws_iam_role_policy_attachment.karpenter_reap_logs,
  ]
}
