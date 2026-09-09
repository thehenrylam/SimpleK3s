"""Bootstrap generation reporting.

The rule that matters: `stale` is only a verdict when BOTH sides are known.
An unreadable bucket must never make a current node look stale, and a node
with no stamp must never look current.
"""

import types

from sk3s_verify import generation


def test_both_known_and_equal_is_not_stale():
    assert generation.state("abc123", "abc123")["stale"] is False


def test_both_known_and_different_is_stale():
    result = generation.state("abc123", "def456")
    assert result["stale"] is True
    assert result["synced"] == "abc123"
    assert result["current"] == "def456"


def test_unreadable_bucket_is_unknown_not_stale():
    assert generation.state("abc123", "")["stale"] is None


def test_node_without_a_stamp_is_unknown_not_current():
    assert generation.state("", "def456")["stale"] is None


def test_neither_known_is_unknown():
    assert generation.state("", "")["stale"] is None


def test_recorded_reads_the_stamp(tmp_path):
    stamp = tmp_path / generation.STAMP_NAME
    stamp.write_text("bf4d992d59a8\n")
    assert generation.recorded(str(stamp)) == "bf4d992d59a8"


def test_recorded_is_none_when_absent(tmp_path):
    assert generation.recorded(str(tmp_path / generation.STAMP_NAME)) is None


def test_recorded_is_none_when_empty(tmp_path):
    stamp = tmp_path / generation.STAMP_NAME
    stamp.write_text("\n")
    assert generation.recorded(str(stamp)) is None


def test_node_env_parses_shell_assignments(tmp_path):
    (tmp_path / "simplek3s.env").write_text(
        '# a comment\nS3_BUCKET_NAME="s3-k3s-demo"\nAWS_REGION="us-east-1"\n\nBARE=value\n'
    )
    env = generation.node_env(str(tmp_path))
    assert env["S3_BUCKET_NAME"] == "s3-k3s-demo"
    assert env["AWS_REGION"] == "us-east-1"
    assert env["BARE"] == "value"


def test_node_env_missing_file_is_empty(tmp_path):
    assert generation.node_env(str(tmp_path)) == {}


def test_current_is_none_without_bucket_config():
    assert generation.current(env={}) is None


# ─── Paths ───────────────────────────────────────────────────────────────────
#
# The stamp used to be written by bash to one directory and read by this module
# from another, so it was never once found. These pin both sides to one answer.


def test_the_stamp_lives_outside_the_s3_sync_destination():
    """Everything under /opt/simplek3s is a bucket mirror; state cannot live there.

    This is what lets #158 turn on `aws s3 sync --delete` safely.
    """
    assert not generation.DEFAULT_STATE_DIR.startswith("/opt/simplek3s")
    assert generation.stamp_path() == "/var/lib/simplek3s/.simplek3s-generation"


def test_state_dir_is_overridable(monkeypatch):
    monkeypatch.setenv("SK3S_STATE_DIR", "/tmp/sk3s-test")
    assert generation.stamp_path() == "/tmp/sk3s-test/.simplek3s-generation"


def test_bootstrap_dir_does_not_leak_in_from_the_shell(monkeypatch):
    """BOOTSTRAP_DIR means the sync ROOT in the node's shell, not this directory.

    Honouring it here silently pointed the module at a directory holding neither
    the stamp nor simplek3s.env, whenever Python was launched from a shell that
    had exported it.
    """
    monkeypatch.setenv("BOOTSTRAP_DIR", "/opt/simplek3s/")
    assert generation.script_dir() == generation.DEFAULT_SCRIPT_DIR
    assert generation.stamp_path() == "/var/lib/simplek3s/.simplek3s-generation"


# ─── record ──────────────────────────────────────────────────────────────────


def test_record_writes_a_stamp_that_recorded_reads_back(tmp_path, monkeypatch):
    monkeypatch.setenv("SK3S_STATE_DIR", str(tmp_path / "state"))
    assert generation.record("abc123def456") == "abc123def456"
    assert generation.recorded() == "abc123def456"


def test_record_creates_the_state_directory(tmp_path, monkeypatch):
    target = tmp_path / "does" / "not" / "exist"
    monkeypatch.setenv("SK3S_STATE_DIR", str(target))
    assert generation.record("abc123def456") == "abc123def456"
    assert (target / generation.STAMP_NAME).exists()


def test_record_leaves_a_good_stamp_alone_when_the_bucket_is_unreadable(tmp_path, monkeypatch):
    """A stale stamp beats a wrong one; both report unknown either way."""
    monkeypatch.setenv("SK3S_STATE_DIR", str(tmp_path))
    generation.record("aaaaaaaaaaaa")
    monkeypatch.setattr(generation, "current", lambda: None)
    assert generation.record() is None
    assert generation.recorded() == "aaaaaaaaaaaa"


# ─── digest ──────────────────────────────────────────────────────────────────


def test_a_trailing_newline_cannot_change_the_digest(monkeypatch):
    """The exact divergence between the old bash and Python implementations.

    bash captured the listing with $( ), stripping the trailing newline; this
    module hashed stdout verbatim. One unchanged bucket produced 7167d2800a11
    and 01245e9fa49e, so `stale` could never be false.
    """
    listing = b'bootstrap/default/node_init-all.sh\t"abc"\t1234'

    def digest_of(stdout):
        monkeypatch.setattr(
            generation.subprocess,
            "run",
            lambda *a, **k: types.SimpleNamespace(returncode=0, stdout=stdout),
        )
        return generation.current({"S3_BUCKET_NAME": "b", "AWS_REGION": "r"})

    assert digest_of(listing) == digest_of(listing + b"\n") == digest_of(listing + b"\n\n")


def test_a_whitespace_only_listing_is_unknown_not_a_digest(monkeypatch):
    monkeypatch.setattr(
        generation.subprocess,
        "run",
        lambda *a, **k: types.SimpleNamespace(returncode=0, stdout=b"\n  \n"),
    )
    assert generation.current({"S3_BUCKET_NAME": "b", "AWS_REGION": "r"}) is None


# ─── legacy stamp cleanup ────────────────────────────────────────────────────


def test_record_removes_the_stamp_the_old_bash_left_behind(tmp_path, monkeypatch):
    """An in-place upgrade must not leave two files answering the same question."""
    legacy = tmp_path / "legacy-stamp"
    legacy.write_text("7167d2800a11\n")
    monkeypatch.setattr(generation, "LEGACY_STAMP", str(legacy))
    monkeypatch.setattr(generation, "DEFAULT_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.delenv("SK3S_STATE_DIR", raising=False)

    assert generation.record("abc123def456") == "abc123def456"
    assert not legacy.exists()
    assert generation.recorded() == "abc123def456"


def test_a_redirected_state_dir_never_deletes_outside_its_sandbox(tmp_path, monkeypatch):
    legacy = tmp_path / "legacy-stamp"
    legacy.write_text("7167d2800a11\n")
    monkeypatch.setattr(generation, "LEGACY_STAMP", str(legacy))
    monkeypatch.setenv("SK3S_STATE_DIR", str(tmp_path / "elsewhere"))

    assert generation.record("abc123def456") == "abc123def456"
    assert legacy.exists()


def test_a_missing_legacy_stamp_is_not_an_error(tmp_path, monkeypatch):
    monkeypatch.setattr(generation, "LEGACY_STAMP", str(tmp_path / "never-existed"))
    monkeypatch.setattr(generation, "DEFAULT_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.delenv("SK3S_STATE_DIR", raising=False)
    assert generation.record("abc123def456") == "abc123def456"
