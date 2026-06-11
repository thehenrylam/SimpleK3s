#!/usr/bin/env python3

# Builtin Modules
import subprocess
import shlex
from dataclasses import dataclass

# This class + function is meant to help make SHELL commands easier to execute
@dataclass
class CommandResult:
    stdout:     str
    stderr:     str
    returncode: int

    @property
    def ok(self) -> bool:
        return self.returncode == 0

def run_command(cmd: str | list, timeout: int = 30) -> CommandResult:
    if isinstance(cmd, str):
        cmd = shlex.split(cmd)

    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return CommandResult(
            stdout=proc.stdout.strip(),
            stderr=proc.stderr.strip(),
            returncode=proc.returncode,
        )
    except FileNotFoundError:
        return CommandResult(stdout="", stderr=f"command not found: {cmd[0]}", returncode=-1)
    except subprocess.TimeoutExpired:
        return CommandResult(stdout="", stderr=f"command timed out after {timeout}s", returncode=-1)
