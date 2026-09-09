"""On-node cluster verification.

Stdlib only, by rule: this runs on the node's system python3 and must never
depend on an interpreter environment stored inside the directory it verifies.

The package is importable so the check logic can be unit-tested off-cluster
against fakes. Nothing here may run at import time.
"""

SCHEMA = 2
