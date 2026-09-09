"""The query layer: a failed question must never look like a healthy answer.

These drive the real subprocess path against a fake kubectl on PATH, so the
seam being tested is the one that actually runs on a node.
"""

import os
import stat

import pytest
from sk3s_verify import kube


def _fake_kubectl(tmp_path, body):
    path = tmp_path / "kubectl"
    path.write_text("#!/bin/bash\n" + body + "\n")
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    return str(tmp_path)


@pytest.fixture
def with_kubectl(tmp_path, monkeypatch):
    def install(body):
        monkeypatch.setenv("PATH", _fake_kubectl(tmp_path, body) + os.pathsep + os.environ["PATH"])

    return install


def test_run_returns_stdout(with_kubectl):
    with_kubectl("echo hello")
    assert kube.run(["get", "nodes"]).strip() == "hello"


def test_failed_query_raises_rather_than_returning_empty(with_kubectl):
    # The #156 shape: previously this produced "" and callers read "" as healthy.
    with_kubectl('echo "connection refused" >&2; exit 1')
    with pytest.raises(kube.Unavailable) as exc:
        kube.run(["get", "nodes"])
    assert "connection refused" in str(exc.value)


def test_unparseable_json_raises(with_kubectl):
    # #156's worst instance caught JSONDecodeError and reported success.
    with_kubectl('echo "this is not json"')
    with pytest.raises(kube.Unavailable):
        kube.run_json(["get", "nodes"])


def test_run_json_parses(with_kubectl):
    with_kubectl("echo '{\"items\":[]}'")
    assert kube.run_json(["get", "nodes"]) == {"items": []}


def test_exists_false_only_for_a_real_not_found(with_kubectl):
    with_kubectl('echo "Error from server (NotFound): not found" >&2; exit 1')
    assert kube.exists(["get", "ns", "nope"]) is False


def test_exists_raises_when_kubectl_cannot_run(with_kubectl):
    # Absence of an ANSWER is not absence of a namespace.
    with_kubectl('echo "connection refused" >&2; exit 1')
    with pytest.raises(kube.Unavailable):
        kube.exists(["get", "ns", "monitoring"])


def test_missing_kubectl_raises(monkeypatch, tmp_path):
    monkeypatch.setenv("PATH", str(tmp_path))
    with pytest.raises(kube.Unavailable):
        kube.run(["get", "nodes"])
