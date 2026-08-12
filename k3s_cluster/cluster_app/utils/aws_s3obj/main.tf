terraform {
  required_version = "~> 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

locals {
  tags_default = {
    Nickname = var.nickname
    Module   = var.module_name
  }

  # Render every object's content in-memory, up front:
  #   - templated entries (template != null) -> rendered from their "<src>.tmpl" companion
  #   - plain entries      (template == null) -> read directly from "<src>"
  #
  # Uploading the rendered content directly (rather than writing it to disk via a
  # local_file resource and uploading it by `source`) keeps `tofu plan` idempotent.
  # Previously, the rendered files were gitignored build artifacts; on a fresh clone
  # or after `git clean` they were "missing", which made local_file plan a recreate
  # and cascaded into re-uploading every S3 object. Computing content from the
  # committed source / ".tmpl" files removes that working-directory dependency. (issue #85)
  #
  # Keyed by S3 key, NOT by list position. Under the previous `count`, each object
  # was addressed by its index in s3obj_data, so inserting or removing one entry
  # renumbered every entry after it and Terraform destroyed and recreated all of
  # them. On a bootstrap bucket that nodes sync from, that is a window in which
  # files briefly do not exist — for a change that touched none of them.
  # An address derived from the object's own key is independent of whatever sits
  # around it in the list.
  #
  # The INPUT is still a list: callers pass s3obj_data exactly as before. Only the
  # internal addressing changed. This mirrors the sibling utils/aws_pstore module,
  # which already projects its list input into a map keyed by name.
  #
  # A duplicate key now fails at plan time ("Two different items produced the key
  # ...") rather than silently racing two uploads at the same object.
  s3obj_rendered = {
    for o in var.s3obj_data : o.key => (
      o.template == null ? file(o.src) : templatefile("${o.src}.tmpl", jsondecode(o.template))
    )
  }
}

###################################
#    S3 Files : Bootstrapping     #
###################################
# Upload the (rendered) data files to S3.
resource "aws_s3_object" "s3obj" {
  for_each = local.s3obj_rendered

  bucket  = var.s3_bucket_id
  key     = each.key
  content = each.value
  # Explicit content hash so the provider only re-uploads on a real content change.
  etag = md5(each.value)

  tags = merge(var.tags, local.tags_default, {
    Name = each.key
  })
}
