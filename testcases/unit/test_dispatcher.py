"""The sk3s dispatcher's verb table.

The table is a "|"-separated array parsed by a bash helper. That is fine for the
first three fields, which are tokens, but the summary is free text and
legitimately contains "|" — the --depth values do. Cutting it at a delimiter
truncated the help to "(--depth quick", which is the first line a new operator
reads and looked like a broken CLI.

shellcheck cannot see this: the script was valid bash the whole time. So the
guard is behavioural — run the dispatcher and check each summary survives whole.
"""

import pathlib
import re
import subprocess

SK3S = pathlib.Path(__file__).resolve().parents[2] / "examples" / "standard_deployment" / "sk3s"


def verb_table():
    """(verb, summary) for every entry in the script's VERBS array."""
    source = SK3S.read_text()
    block = re.search(r"^VERBS=\((.*?)^\)", source, re.MULTILINE | re.DOTALL)
    assert block, "VERBS array not found in the dispatcher"
    entries = re.findall(r'"([^"]+)"', block.group(1))
    assert entries, "VERBS array parsed as empty"
    table = []
    for entry in entries:
        # The summary is the LAST field, so it is everything after the 3rd pipe
        # — the exact rule the dispatcher itself has to follow.
        fields = entry.split("|", 3)
        assert len(fields) == 4, f"malformed verb entry: {entry!r}"
        table.append((fields[0], fields[3]))
    return table


def help_output():
    """Usage goes to stderr, which is correct for an exit-2 usage error."""
    done = subprocess.run([str(SK3S)], capture_output=True, text=True, timeout=60)
    return done.stderr


def test_the_dispatcher_lists_every_verb():
    output = help_output()
    for verb, _ in verb_table():
        assert f"  {verb}" in output, f"{verb} missing from help"


def test_every_summary_is_printed_whole():
    """A summary containing '|' must not be cut at it."""
    output = help_output()
    for verb, summary in verb_table():
        assert summary in output, f"{verb} summary truncated; expected {summary!r}"


def test_the_status_summary_still_advertises_all_three_depths():
    """The specific regression: this summary is the one carrying pipes."""
    output = help_output()
    assert "--depth quick|standard|full" in output


def test_bare_invocation_is_a_usage_error_not_a_crash():
    done = subprocess.run([str(SK3S)], capture_output=True, text=True, timeout=60)
    assert done.returncode == 2
    assert "Usage:" in done.stderr
    # Usage must not contaminate stdout: `sk3s status --json` is piped into
    # other tools, so the two streams have to stay separated.
    assert done.stdout == ""
