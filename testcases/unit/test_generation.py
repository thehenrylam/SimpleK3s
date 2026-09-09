"""Bootstrap generation reporting.

The rule that matters: `stale` is only a verdict when BOTH sides are known.
An unreadable bucket must never make a current node look stale, and a node
with no stamp must never look current.
"""

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
    (tmp_path / generation.STAMP_NAME).write_text("bf4d992d59a8\n")
    assert generation.recorded(str(tmp_path)) == "bf4d992d59a8"


def test_recorded_is_none_when_absent(tmp_path):
    assert generation.recorded(str(tmp_path)) is None


def test_recorded_is_none_when_empty(tmp_path):
    (tmp_path / generation.STAMP_NAME).write_text("\n")
    assert generation.recorded(str(tmp_path)) is None


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
