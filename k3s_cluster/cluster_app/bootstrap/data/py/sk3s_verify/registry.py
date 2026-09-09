"""Check registration, depth selection, and result recording.

A check declares the depth at which it becomes relevant. Running at a depth
runs every check at that depth or shallower, so depth is a widening of one
definition of healthy rather than a second definition.
"""

from . import kube

QUICK, STANDARD, FULL = "quick", "standard", "full"
DEPTHS = (QUICK, STANDARD, FULL)

PASSED, FAILED, SKIPPED = "passed", "failed", "skipped"

_REGISTRY = []


def check(section, depth=STANDARD):
    """Register a check function under a section name at a depth."""

    def wrap(fn):
        _REGISTRY.append({"section": section, "depth": depth, "fn": fn})
        return fn

    return wrap


def registered(depth):
    """Checks that apply at the given depth, in registration order."""
    limit = DEPTHS.index(depth)
    return [c for c in _REGISTRY if DEPTHS.index(c["depth"]) <= limit]


class Recorder:
    """Collects assertions for one node's run."""

    def __init__(self):
        self.checks = []
        self.facts = {}

    def passed(self, section, message):
        self.checks.append({"section": section, "result": PASSED, "message": message})

    def failed(self, section, message, detail=None):
        entry = {"section": section, "result": FAILED, "message": message}
        if detail:
            entry["detail"] = detail
        self.checks.append(entry)

    def skipped(self, section, message):
        """Deliberately distinct from passed. A subsystem that is not deployed
        has not been verified, and reporting absence as success is the defect
        class of #110."""
        self.checks.append({"section": section, "result": SKIPPED, "message": message})

    def fact(self, key, value):
        """Observed state, carried at full depth. Facts are NOT graded here —
        the answer sheet lives outside this tool and consumes what we report."""
        self.facts[key] = value

    @property
    def counts(self):
        out = {PASSED: 0, FAILED: 0, SKIPPED: 0}
        for entry in self.checks:
            out[entry["result"]] += 1
        return out


def run_all(depth):
    """Run every check for the depth. An Unavailable escaping a check becomes a
    failure, never a skip: the check was supposed to run and did not answer."""
    rec = Recorder()
    for entry in registered(depth):
        section = entry["section"]
        try:
            entry["fn"](rec)
        except kube.Unavailable as exc:
            rec.failed(section, f"{section}: could not determine state", str(exc))
        except Exception as exc:  # noqa: BLE001 - a crashing check must not pass
            rec.failed(section, f"{section}: check raised {type(exc).__name__}", str(exc))
    return rec
