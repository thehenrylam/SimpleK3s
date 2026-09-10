"""The deployment roots' names, as they appear in prose.

The four Terraform roots were renamed — ex_idp, ex_basic, ex_pvc, ex_tailscale
became standard_idp, standard_cluster, standard_pvc, standard_tailscale — and 62
references across 15 files were not swept with them. Comments pointed at
directories that had not existed for months, a sub-README's title named a root
that was gone, and two `outputs.tf` descriptions carried the old name into
`tofu output`.

Nothing was broken by it, which is exactly why it survived: stale prose fails no
test and blocks no apply. So this is the test.
"""

import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]

RENAMED = {
    "ex_idp": "standard_idp",
    "ex_basic": "standard_cluster",
    "ex_pvc": "standard_pvc",
    "ex_tailscale": "standard_tailscale",
}

# Word-bounded so "index_", "regex_" and friends cannot match.
PATTERN = re.compile(r"\bex_(idp|basic|pvc|tailscale)\b")


def tracked_files():
    """Only tracked files: gitignored scratch dirs are not repository content."""
    out = subprocess.run(
        ["git", "ls-files", "-z"], capture_output=True, cwd=str(ROOT), timeout=120
    ).stdout.decode()
    return [name for name in out.split("\0") if name]


def test_no_tracked_file_references_a_renamed_root():
    offenders = []
    for name in tracked_files():
        if name == pathlib.Path(__file__).name or name.endswith("test_root_names.py"):
            continue
        try:
            text = (ROOT / name).read_text()
        except (UnicodeDecodeError, OSError):
            continue
        for match in PATTERN.finditer(text):
            offenders.append(f"{name}: ex_{match.group(1)} -> {RENAMED['ex_' + match.group(1)]}")
    assert offenders == [], "renamed roots still referenced:\n  " + "\n  ".join(offenders)


def test_every_replacement_root_actually_exists():
    """A rename target that does not exist would be a worse comment than the old one."""
    roots = ROOT / "examples" / "standard_deployment" / "terraform"
    for new in RENAMED.values():
        assert (roots / new).is_dir(), f"{new} is not a Terraform root"


def test_the_lambda_zip_ignore_still_matches_the_real_path():
    """The explicit ex_tailscale path went stale; only the glob was doing the work."""
    target = "examples/standard_deployment/terraform/standard_tailscale/data/cleanup_devices.zip"
    done = subprocess.run(
        ["git", "check-ignore", target], capture_output=True, cwd=str(ROOT), timeout=60
    )
    assert done.returncode == 0, f"{target} is no longer gitignored"
