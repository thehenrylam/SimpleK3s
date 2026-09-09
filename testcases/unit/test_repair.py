"""`sk3s repair` previews by default.

This mutates a control plane — it removes etcd members and joins nodes — so the
default has to be the safe one. It was not: the script applied unless given
--dry-run, while cluster_repair.yml previewed unless given -e repair_apply=true.
The same operation defaulted in opposite directions depending on which entry
point you used.

The script needs AWS to do anything real, so the behavioural surface testable
here is its usage contract. The default itself is asserted against the source,
which is weaker than running it but does catch an accidental re-flip.
"""

import pathlib
import re
import subprocess

DEPLOYMENT = pathlib.Path(__file__).resolve().parents[2] / "examples" / "standard_deployment"
SCRIPT = DEPLOYMENT / "scripts" / "ssm_repair_cluster.sh"
SK3S = DEPLOYMENT / "sk3s"


def help_text(argv):
    done = subprocess.run(argv, capture_output=True, text=True, cwd=str(DEPLOYMENT), timeout=120)
    return done.stdout + done.stderr


# ─── The default ─────────────────────────────────────────────────────────────


def test_the_declared_default_is_preview():
    source = SCRIPT.read_text()
    assert re.search(r"^DRY_RUN=1$", source, re.MULTILINE), "repair must default to preview"
    assert not re.search(r"^DRY_RUN=0$", source, re.MULTILINE)


def test_apply_is_the_only_thing_that_clears_the_preview():
    """Exactly one flag turns this into a mutation, and it is named --apply."""
    source = SCRIPT.read_text()
    clears = re.findall(r"^\s*(--[a-z-]+)\)\s*DRY_RUN=0", source, re.MULTILINE)
    assert clears == ["--apply"]


# ─── Usage contract ──────────────────────────────────────────────────────────


def test_usage_advertises_apply():
    out = help_text([str(SCRIPT), "--help"])
    assert "--apply" in out
    assert "Without it, nothing is changed" in out


def test_usage_no_longer_advertises_dry_run_as_the_way_to_preview():
    """It is still accepted, but presenting it as the opt-in would be backwards."""
    out = help_text([str(SCRIPT), "--help"])
    assert "[--apply]" in out
    assert "[--dry-run]" not in out


def test_dry_run_is_still_accepted_for_compatibility():
    """An existing invocation should keep working and keep meaning what it says."""
    source = SCRIPT.read_text()
    assert re.search(r"^\s*--dry-run\)\s*DRY_RUN=1", source, re.MULTILINE)


def test_help_is_reachable_through_the_dispatcher():
    assert "--apply" in help_text([str(SK3S), "repair", "--help"])


# ─── The playbook it replaces ────────────────────────────────────────────────


def test_the_repair_playbook_is_gone():
    """It existed to invert the default; one safe default removes the need."""
    assert not (DEPLOYMENT / "playbooks" / "cluster_repair.yml").exists()


def test_nothing_still_points_at_the_deleted_playbook():
    """Except the script's own note explaining why the default changed.

    Scoped to TRACKED files via git ls-files: scratch directories like _tmp/ are
    gitignored working notes, not repository content, and walking the whole tree
    also picks up .terraform provider caches.
    """
    root = DEPLOYMENT.parent.parent
    tracked = subprocess.run(
        ["git", "ls-files", "-z"], capture_output=True, cwd=str(root), timeout=120
    ).stdout.decode()
    stale = []
    for name in tracked.split("\0"):
        if not name or name.endswith((".log", "test_repair.py", "ssm_repair_cluster.sh")):
            continue
        path = root / name
        try:
            if "cluster_repair.yml" in path.read_text():
                stale.append(name)
        except (UnicodeDecodeError, OSError):
            continue
    assert stale == [], f"stale references to a deleted playbook: {stale}"
