"""The `sk3s infra` namespace.

WHY A STUB. These assert on the ansible-playbook invocation, never on its
effects — the verbs under test include `destroy`, and a test that reaches a real
playbook is a test that can tear down infrastructure. A fake ansible-playbook is
put on PATH and the tests read what it was handed.

(Not hypothetical: while developing this, invoking `support destroy --check`
by hand to inspect argument passthrough started a real playbook. It only reached
the tfvars gate before being killed, but the correct way to ask that question is
the stub below.)
"""

import os
import pathlib
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEPLOYMENT = ROOT / "examples" / "standard_deployment"
INFRA = DEPLOYMENT / "scripts" / "infra.sh"
SK3S = DEPLOYMENT / "sk3s"

TIERS = ("cluster", "support")
VERBS = ("plan", "apply", "destroy")


@pytest.fixture(scope="module")
def stub_path(tmp_path_factory):
    """A PATH whose ansible-playbook only echoes its arguments."""
    directory = tmp_path_factory.mktemp("stub")
    fake = directory / "ansible-playbook"
    fake.write_text(
        "#!/bin/bash\nprintf 'STUB:'; for a in \"$@\"; do printf ' %s' \"$a\"; done; echo\n"
    )
    fake.chmod(0o755)
    return f"{directory}{os.pathsep}{os.environ['PATH']}"


def run(argv, stub_path=None, cwd=DEPLOYMENT):
    env = dict(os.environ)
    if stub_path:
        env["PATH"] = stub_path
    return subprocess.run(argv, capture_output=True, text=True, cwd=str(cwd), env=env, timeout=120)


def invocation(done):
    for line in done.stdout.splitlines():
        if line.startswith("STUB:"):
            return line[len("STUB:") :].split()
    raise AssertionError(f"ansible-playbook was not invoked. stdout={done.stdout!r}")


# ─── Dispatch ────────────────────────────────────────────────────────────────


@pytest.mark.parametrize("tier", TIERS)
@pytest.mark.parametrize("verb", VERBS)
def test_every_tier_and_verb_maps_to_its_playbook(stub_path, tier, verb):
    """The playbook name is derived, so there is no table to drift out of step."""
    done = run([str(INFRA), tier, verb], stub_path)
    assert done.returncode == 0
    assert invocation(done)[0].endswith(f"playbooks/{tier}_{verb}.yml")


def test_arguments_after_the_verb_pass_straight_through(stub_path):
    done = run([str(INFRA), "support", "destroy", "--limit", "!idp"], stub_path)
    assert invocation(done)[1:] == ["--limit", "!idp"]


def test_the_documented_idp_exclusion_survives_as_one_argument(stub_path):
    """'!idp' must not be split or glob-expanded on its way to Ansible."""
    done = run([str(INFRA), "support", "destroy", "--limit", "!idp"], stub_path)
    assert "!idp" in invocation(done)


def test_infra_is_reachable_through_the_sk3s_dispatcher(stub_path):
    done = run([str(SK3S), "infra", "cluster", "plan", "-e", "foo=bar"], stub_path)
    argv = invocation(done)
    assert argv[0].endswith("playbooks/cluster_plan.yml")
    assert argv[1:] == ["-e", "foo=bar"]


def test_sk3s_does_not_inject_a_profile_into_infra(stub_path):
    """Infra reads group_vars; an injected profile would look like a tier name."""
    done = run([str(SK3S), "infra"], stub_path)
    assert "Profile  :" not in done.stdout + done.stderr


# ─── Refusals ────────────────────────────────────────────────────────────────


def test_bare_infra_shows_usage_as_a_usage_error():
    done = run([str(INFRA)])
    assert done.returncode == 2
    assert "Usage: sk3s infra <tier> <verb>" in done.stderr


def test_help_goes_to_stdout_and_exits_zero():
    """A pipeline asking for help must not be fed it on stderr, or vice versa."""
    done = run([str(INFRA), "--help"])
    assert done.returncode == 0
    assert "Usage: sk3s infra <tier> <verb>" in done.stdout
    assert done.stderr == ""


def test_an_unknown_tier_is_refused_and_names_the_known_ones():
    done = run([str(INFRA), "bogus", "apply"])
    assert done.returncode == 2
    assert "unknown tier 'bogus'" in done.stderr
    assert "cluster, support" in done.stderr


def test_an_unknown_verb_is_refused_and_names_the_known_ones():
    done = run([str(INFRA), "cluster", "bogus"])
    assert done.returncode == 2
    assert "unknown verb 'bogus'" in done.stderr
    assert "plan, apply, destroy" in done.stderr


def test_a_tier_without_a_verb_is_refused():
    """Never default to a verb here: the plausible default is 'apply'."""
    done = run([str(INFRA), "cluster"])
    assert done.returncode == 2
    assert "needs a verb" in done.stderr


def test_nothing_is_invoked_when_the_arguments_are_refused(stub_path):
    for argv in ([str(INFRA)], [str(INFRA), "bogus", "apply"], [str(INFRA), "cluster", "bogus"]):
        assert "STUB:" not in run(argv, stub_path).stdout


# ─── Documentation the help promises ─────────────────────────────────────────


def test_help_documents_the_idp_exclusion_and_why_it_matters():
    """The most-used command in this repo; MAU cost is not discoverable."""
    out = run([str(INFRA), "--help"]).stdout
    assert "--limit '!idp'" in out
    assert "monthly active" in out.lower()


def test_help_states_the_teardown_ordering():
    out = run([str(INFRA), "--help"]).stdout
    assert "destroy cluster before support" in out.lower()


def test_every_advertised_tier_and_verb_has_a_playbook_on_disk():
    """A row in the table with no playbook is a packaging error, not an operator one."""
    for tier in TIERS:
        for verb in VERBS:
            assert (DEPLOYMENT / "playbooks" / f"{tier}_{verb}.yml").is_file()


def test_the_retired_update_playbook_is_gone():
    assert not (DEPLOYMENT / "playbooks" / "cluster_update.yml").exists()
