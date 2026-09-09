"""Packaging the on-node verifier for inline delivery.

WHY INLINE. The verifier is zipped and shipped with every invocation rather than
read from the node's disk, so the node always runs exactly the version the
caller expects. That removes version skew during a rollout — and with it the
dual-schema handling a staged deploy would otherwise need, since host and node
can never disagree about the document format.

Measured on a live cluster: the package is ~17.6 KB of base64 against an input
ceiling proven to accept at least 96 KB, so there is roughly 5x headroom.
"""

import base64
import gzip
import io
import json
import os
import zipfile

PACKAGE = "sk3s_verify"

# Executed by `python3 <file.pyz>`; a zip with a top-level __main__.py is
# directly runnable, so no unpacking step is needed on the node.
_BOOTSTRAP = "import sys\nfrom sk3s_verify.__main__ import main\nsys.exit(main())\n"


def source_dir(repo_root):
    return os.path.join(repo_root, "k3s_cluster", "cluster_app", "bootstrap", "data", "py")


def build(repo_root):
    """Zip the verifier package and return it base64-encoded."""
    root = source_dir(repo_root)
    package_dir = os.path.join(root, PACKAGE)
    if not os.path.isdir(package_dir):
        raise FileNotFoundError(f"verifier package not found at {package_dir}")

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as archive:
        for dirpath, _, filenames in os.walk(package_dir):
            for filename in sorted(filenames):
                if not filename.endswith(".py"):
                    continue
                full = os.path.join(dirpath, filename)
                archive.write(full, os.path.relpath(full, root))
        archive.writestr("__main__.py", _BOOTSTRAP)
    return base64.b64encode(buf.getvalue()).decode()


def remote_command(encoded, depth, env=None):
    """The shell command that runs the verifier on a node and cleans up.

    mktemp rather than a fixed path so two concurrent runs cannot overwrite each
    other's payload, and the exit status is preserved across the cleanup so the
    node's verdict still reaches SSM.
    """
    # Values are interpolated into a shell command, so anything that is not a
    # bare token is refused rather than quoted-and-hoped. These are numeric
    # tunables; nothing legitimate needs a shell metacharacter.
    safe = {}
    for key, value in sorted((env or {}).items()):
        text = str(value)
        if not text.isalnum():
            raise ValueError(f"refusing to forward {key}={text!r}: not an alphanumeric token")
        safe[key] = text
    assignments = "".join(f"{k}={v} " for k, v in safe.items())
    return (
        "P=$(mktemp /tmp/sk3s_verify.XXXXXX.pyz) && "
        f"printf '%s' '{encoded}' | base64 -d > \"$P\" && "
        f'{assignments}python3 "$P" --depth {depth} --compress; '
        'rc=$?; rm -f "$P"; exit $rc'
    )


def decode(payload):
    """Decode a node's compressed document.

    Raises ValueError on anything unreadable. A document we cannot parse is not
    an empty one, and must never be counted as a node with nothing to report.
    """
    text = payload.strip()
    if not text:
        raise ValueError("node returned no output")
    try:
        return json.loads(gzip.decompress(base64.b64decode(text, validate=True)).decode())
    except Exception as exc:
        raise ValueError(f"could not decode the node's report: {exc}") from exc
