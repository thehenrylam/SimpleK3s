"""Check declaration, depth selection, and the failure semantics of the runner.

Two things here are deliberately awkward to get wrong.

REGISTRATION IS EXPLICIT. Checks are listed in one place (checks.build_registry)
rather than collected by an import-time decorator. Import order therefore cannot
change what runs or in what order, there is no module state for a test to
corrupt, and the full set of checks and their depths is readable in a single
screen instead of scattered across decorators.

A CHECK CANNOT NAME ITS OWN SECTION. The runner hands each check a recorder
already bound to that check's section, so a check calls rec.passed(message) and
has no opportunity to record against the wrong one. Previously the section
string was repeated in the decorator and in every call inside the function, and
nothing detected a typo — the result simply appeared under a section that did
not exist.
"""

from collections.abc import Callable
from dataclasses import dataclass

from . import kube

QUICK, STANDARD, FULL = "quick", "standard", "full"
DEPTHS = (QUICK, STANDARD, FULL)

PASSED, FAILED, SKIPPED = "passed", "failed", "skipped"


@dataclass(frozen=True)
class Check:
    """One subsystem's health definition, and the depth it becomes relevant at."""

    section: str
    depth: str
    run: Callable


class Results:
    """Everything one node's run observed."""

    def __init__(self):
        self.checks = []
        self.facts = {}

    @property
    def counts(self):
        out = {PASSED: 0, FAILED: 0, SKIPPED: 0}
        for entry in self.checks:
            out[entry["result"]] += 1
        return out


class SectionRecorder:
    """A recorder bound to one section. Checks receive this, never Results."""

    def __init__(self, results, section):
        self._results = results
        self._section = section

    def passed(self, message):
        self._results.checks.append(
            {"section": self._section, "result": PASSED, "message": message}
        )

    def failed(self, message, detail=None):
        entry = {"section": self._section, "result": FAILED, "message": message}
        if detail:
            entry["detail"] = detail
        self._results.checks.append(entry)

    def skipped(self, message):
        """Deliberately distinct from passed. A subsystem that is not deployed
        has not been verified, and reporting absence as success is the defect
        class of #110."""
        self._results.checks.append(
            {"section": self._section, "result": SKIPPED, "message": message}
        )

    def verdict(self, ok, message):
        """Record a boolean outcome. Exists so a check cannot pass on one branch
        and silently return on the other — the shape that made check_longhorn
        record zero assertions."""
        (self.passed if ok else self.failed)(message)

    def fact(self, key, value):
        """Observed state, carried at full depth and namespaced under this
        section so two subsystems cannot collide on a key. Facts are NOT graded
        here — grading lives outside this tool and consumes what we report."""
        self._results.facts[f"{self._section}.{key}"] = value


def select(registry, depth):
    """Checks that apply at the given depth, in declaration order."""
    limit = DEPTHS.index(depth)
    return [c for c in registry if DEPTHS.index(c.depth) <= limit]


def run_all(registry, depth):
    """Run the selected checks.

    A check has three ways to finish and two of them are failures: an
    Unavailable means the question could not be answered, and any other
    exception means the check itself is broken. Neither is a skip, and neither
    is silence — a check that records nothing and throws still produces a
    recorded failure.
    """
    results = Results()
    for check in select(registry, depth):
        rec = SectionRecorder(results, check.section)
        try:
            check.run(rec)
        except kube.Unavailable as exc:
            rec.failed("could not determine state", str(exc))
        except Exception as exc:  # noqa: BLE001 - a crashing check must not pass
            rec.failed(f"check raised {type(exc).__name__}", str(exc))
    return results
