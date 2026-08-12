output "processed_s3obj" {
  description = "The S3 keys set up for the cluster_app, sorted. Order is NOT meaningful — do not index into this."
  # Sorted purely so the value is stable between plans. Since the resource is
  # keyed by S3 key (a map), iteration is lexicographic rather than the order of
  # the caller's s3obj_data list — so positional access like [0] no longer means
  # "the first entry the caller wrote". Anything needing a specific object must
  # name its key, not its position.
  value = sort(keys(aws_s3_object.s3obj))
}
