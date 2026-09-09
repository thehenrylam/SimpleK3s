"""Host-side helpers for the sk3s tooling.

Stdlib only, and AWS is reached through the `aws` CLI rather than boto3, so this
adds no dependency the deployment did not already have. It is the Python
counterpart to scripts/common.sh and is intended to absorb that plumbing as the
remaining verbs are ported.
"""
