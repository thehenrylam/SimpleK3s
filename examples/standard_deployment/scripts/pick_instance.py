#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# ///
"""Pick an EC2 instance from a SimpleK3s cluster.

Writes the chosen instance id to stdout so it composes:

    INSTANCE_ID="$(./pick_instance.py --profile p --nickname prod --region us-west-2)"

With --list it prints the same instances as TSV and exits, which is what
non-interactive callers (and tests) use. --demo runs the interface against
built-in fixture data, for working on the layout without a cluster.

Exit codes: 0 chosen, 1 error, 130 cancelled.
"""

from __future__ import annotations

import argparse
import curses
import json
import locale
import math
import os
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime

REFRESH_INTERVAL = 15  # seconds between describe-instances calls
TICK_MS = 1000         # redraw cadence; drives the countdown and costs no API call

# Terminated instances are omitted; they cannot be connected to.
QUERYABLE_STATES = "pending,running,stopping,stopped"

PANEL_HEIGHT = 6
FOOTER_HEIGHT = 2
METER_CELLS = 34

STATE_ORDER = ("running", "pending", "stopping", "shutting-down", "stopped")
STATE_COLOR = {
    "running": "green",
    "pending": "yellow",
    "stopping": "yellow",
    "shutting-down": "yellow",
    "stopped": "red",
}
ROLE_COLOR = {"control-plane": "cyan", "agent": "blue", "karpenter": "magenta", "node": "white"}
ROLE_SHORT = {"control-plane": "ctrl", "agent": "agent", "karpenter": "karp", "node": "node"}

MISSING = "-"        # stored form, kept machine-friendly for --list
MISSING_GLYPH = "—"  # display form


@dataclass(frozen=True)
class Instance:
    instance_id: str
    name: str
    state: str
    instance_type: str
    az: str
    public_ip: str
    private_ip: str
    launch: str      # display form, "YYYY-MM-DD HH:MM"
    launch_raw: str  # sort key, full precision

    @property
    def role(self) -> str:
        lowered = self.name.lower()
        if "controlplane" in lowered or "control-plane" in lowered:
            return "control-plane"
        if "agentplane" in lowered or "agent-plane" in lowered:
            return "agent"
        if "karpenter" in lowered:
            return "karpenter"
        return "node"

    @property
    def launch_short(self) -> str:
        """Drop the year for the picker; the row is tight and it never varies."""
        return self.launch[5:] if len(self.launch) > 5 else self.launch

    def as_tsv(self) -> str:
        return "\t".join([
            self.instance_id, self.name, self.state, self.instance_type,
            self.az, self.public_ip, self.private_ip, self.launch,
        ])


@dataclass
class PickerState:
    region: str
    profile: str
    nickname: str
    refresh_interval: int
    demo: bool = False
    instances: list[Instance] = field(default_factory=list)
    selected: int = 0
    last_refresh: float = 0.0
    error: str | None = None
    message: str | None = None


# ─── Data ────────────────────────────────────────────────────────────────────

def format_launch(raw: str) -> str:
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).strftime("%Y-%m-%d %H:%M")
    except ValueError:
        return raw[:16]


def parse_instances(payload: str) -> list[Instance]:
    """Sorted by AZ then launch time, so the order is stable across refreshes."""
    instances: list[Instance] = []
    for reservation in json.loads(payload).get("Reservations", []):
        for inst in reservation.get("Instances", []):
            name = next(
                (t.get("Value", "") for t in inst.get("Tags", []) if t.get("Key") == "Name"),
                "",
            )
            launch_raw = str(inst.get("LaunchTime", ""))
            instances.append(Instance(
                instance_id=inst.get("InstanceId", ""),
                name=name,
                state=inst.get("State", {}).get("Name", ""),
                instance_type=inst.get("InstanceType", ""),
                az=inst.get("Placement", {}).get("AvailabilityZone", ""),
                public_ip=inst.get("PublicIpAddress") or MISSING,
                private_ip=inst.get("PrivateIpAddress") or MISSING,
                launch=format_launch(launch_raw),
                launch_raw=launch_raw,
            ))
    instances.sort(key=lambda i: (i.az, i.launch_raw))
    return instances


def fetch_instances(region: str, profile: str, nickname: str) -> list[Instance]:
    result = subprocess.run(
        [
            "aws", "ec2", "describe-instances",
            "--region", region,
            "--profile", profile,
            "--filters",
            f"Name=tag:Nickname,Values={nickname}",
            f"Name=instance-state-name,Values={QUERYABLE_STATES}",
            "--output", "json",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "aws ec2 describe-instances failed")
    return parse_instances(result.stdout)


def demo_instances() -> list[Instance]:
    """Fixture data so the interface can be worked on without a cluster."""
    raw = [
        ("i-0b2c3d4e5f6a7b8c", "controlplane-b2", "stopped", "t4g.medium",
         "us-west-2a", MISSING, "10.0.1.12", "2026-07-19T09:00:00+00:00"),
        ("i-0a1b2c3d4e5f6a7b", "controlplane-a1", "running", "t4g.medium",
         "us-west-2a", "54.1.2.3", "10.0.1.11", "2026-07-25T10:04:00+00:00"),
        ("i-0f7a8b9c0d1e2f3a", "controlplane-e5", "running", "t4g.medium",
         "us-west-2b", MISSING, "10.0.2.15", "2026-07-21T11:30:00+00:00"),
        ("i-0c3d4e5f6a7b8c9d", "agentplane-c3", "running", "t4g.small",
         "us-west-2b", MISSING, "10.0.2.30", "2026-07-20T08:00:00+00:00"),
        ("i-09a8b7c6d5e4f3a2", "agentplane-f6", "running", "t4g.small",
         "us-west-2b", MISSING, "10.0.2.31", "2026-07-22T14:12:00+00:00"),
        ("i-0d4e5f6a7b8c9d0e", "karpenter-d4", "pending", "c7g.large",
         "us-west-2c", MISSING, "10.0.3.40", "2026-07-24T12:00:00+00:00"),
    ]
    prefix = "simplek3s-prodcluster_"
    return sorted(
        (
            Instance(
                instance_id=iid, name=prefix + name, state=state, instance_type=itype,
                az=az, public_ip=pub, private_ip=priv,
                launch=format_launch(launch), launch_raw=launch,
            )
            for iid, name, state, itype, az, pub, priv, launch in raw
        ),
        key=lambda i: (i.az, i.launch_raw),
    )


# ─── Name shortening ─────────────────────────────────────────────────────────

def shared_prefix(names: list[str]) -> str:
    """Longest common prefix, trimmed back to a separator.

    Node tags carry the cluster name, which the panel already shows, so dropping
    it buys back roughly twenty columns. Cutting at a separator keeps the
    remainder from starting mid-token.
    """
    if len(names) < 2:
        return ""
    prefix = os.path.commonprefix(names)
    for index in range(len(prefix) - 1, -1, -1):
        if prefix[index] in "_-.":
            candidate = prefix[: index + 1]
            # Never strip so much that a name disappears entirely
            if all(len(n) > len(candidate) for n in names):
                return candidate
    return ""


def display_names(instances: list[Instance]) -> dict[str, str]:
    prefix = shared_prefix([i.name for i in instances])
    cut = len(prefix)
    return {i.instance_id: (i.name[cut:] if cut else i.name) for i in instances}


def glyph(value: str) -> str:
    return MISSING_GLYPH if value == MISSING else value


# ─── Plain-text table (--table) ──────────────────────────────────────────────

def format_table(instances: list[Instance]) -> list[str]:
    names = display_names(instances)
    width = max((len(n) for n in names.values()), default=4)
    lines: list[str] = []
    previous_az = None
    for inst in instances:
        if inst.az != previous_az:
            if previous_az is not None:
                lines.append("")
            lines.append(f"  {inst.az}")
            previous_az = inst.az
        lines.append(
            f"    {inst.state:<9} {names[inst.instance_id]:<{width}}  "
            f"{inst.instance_id:<20}{inst.instance_type:<11}"
            f"{inst.private_ip:<15}{inst.public_ip:<15}{inst.launch}"
        )
    return lines


# ─── Colors ──────────────────────────────────────────────────────────────────

def init_colors() -> dict[str, int]:
    plain = {
        "green": curses.A_NORMAL, "yellow": curses.A_NORMAL, "red": curses.A_NORMAL,
        "cyan": curses.A_BOLD, "blue": curses.A_NORMAL, "magenta": curses.A_NORMAL,
        "white": curses.A_NORMAL, "dim": curses.A_DIM, "frame": curses.A_DIM,
        "rail": curses.A_REVERSE, "select": curses.A_REVERSE | curses.A_BOLD,
        "title": curses.A_BOLD, "key": curses.A_REVERSE, "warn": curses.A_BOLD,
        "section": curses.A_BOLD,
    }
    if not curses.has_colors():
        return plain
    curses.start_color()
    try:
        curses.use_default_colors()
        bg = -1
    except curses.error:
        bg = curses.COLOR_BLACK
    palette = [
        ("green", curses.COLOR_GREEN), ("yellow", curses.COLOR_YELLOW),
        ("red", curses.COLOR_RED), ("cyan", curses.COLOR_CYAN),
        ("blue", curses.COLOR_BLUE), ("magenta", curses.COLOR_MAGENTA),
        ("white", curses.COLOR_WHITE),
    ]
    attrs: dict[str, int] = {}
    for index, (name, color) in enumerate(palette, start=1):
        curses.init_pair(index, color, bg)
        attrs[name] = curses.color_pair(index)
    attrs["cyan"] |= curses.A_BOLD
    attrs["dim"] = curses.A_DIM
    attrs["frame"] = attrs["blue"] | curses.A_DIM
    attrs["title"] = attrs["cyan"]
    attrs["rail"] = curses.A_REVERSE | curses.A_BOLD
    attrs["select"] = curses.A_REVERSE | curses.A_BOLD
    attrs["key"] = attrs["cyan"]
    attrs["warn"] = attrs["yellow"] | curses.A_BOLD
    # AZ rules are structure, not data. White is the one value with no semantic
    # load left — state and role already claim every other hue.
    attrs["section"] = attrs["white"] | curses.A_BOLD
    return attrs


# ─── Drawing primitives ──────────────────────────────────────────────────────

Segment = tuple[str, int]


def put(stdscr, y: int, segments: list[Segment], width: int, height: int,
        override: int | None = None) -> None:
    """Draw coloured segments on one line, optionally forcing a single attr.

    `override` is what makes the selection bar uniform: htop highlights the whole
    row rather than preserving per-column colour inside it.
    """
    if not 0 <= y < height:
        return
    limit = max(0, width - 1)
    x = 0
    for text, attr in segments:
        if x >= limit:
            break
        chunk = text[: limit - x]
        if chunk:
            try:
                stdscr.addstr(y, x, chunk, override if override is not None else attr)
            except curses.error:
                pass
            x += len(chunk)
    if override is not None and x < limit:
        try:
            stdscr.addstr(y, x, " " * (limit - x), override)
        except curses.error:
            pass


def panel_line(segments: list[Segment], width: int, C: dict[str, int],
               trailer: list[Segment] | None = None) -> list[Segment]:
    """Pad a panel row and close it with the right-hand border.

    Without this the box renders open on the right, which reads as a drawing
    glitch rather than a frame.
    """
    trailer = trailer or []
    used = sum(len(text) for text, _ in segments) + sum(len(text) for text, _ in trailer)
    pad = max(1, width - 2 - used)
    return segments + [(" " * pad, 0)] + trailer + [("│", C["frame"])]


def meter(counts: dict[str, int], total: int, cells: int, C: dict[str, int]) -> list[Segment]:
    """Proportional multi-colour bar, htop's CPU meter applied to node state."""
    segments: list[Segment] = [("[", C["frame"])]
    if total <= 0:
        return segments + [("░" * cells, C["dim"]), ("]", C["frame"])]
    previous = 0
    accumulated = 0
    for state in STATE_ORDER:
        accumulated += counts.get(state, 0)
        boundary = round(cells * accumulated / total)
        if boundary > previous:
            segments.append(("█" * (boundary - previous), C[STATE_COLOR.get(state, "white")]))
        previous = boundary
    if previous < cells:
        segments.append(("░" * (cells - previous), C["dim"]))
    segments.append(("]", C["frame"]))
    return segments


@dataclass(frozen=True)
class Columns:
    name: int
    iid: int
    itype: int
    private: int
    public: int

    @classmethod
    def fit(cls, instances: list[Instance], names: list[str]) -> Columns:
        """Size every column to the data actually present.

        Reserving the theoretical maximum (15 for an IPv4) wastes columns a VPC
        never uses, and the space it costs is what pushes the launch year off a
        100-column terminal.
        """
        def sized(values: list[str], header: str) -> int:
            # Two-space gutter, but never narrower than the rail's own label
            return max(len(header) + 2, max((len(v) for v in values), default=0) + 2)

        return cls(
            name=max(12, min(24, max((len(n) for n in names), default=12) + 2)),
            iid=sized([i.instance_id for i in instances], "INSTANCE ID"),
            itype=sized([i.instance_type for i in instances], "TYPE"),
            private=sized([glyph(i.private_ip) for i in instances], "PRIVATE IP"),
            public=sized([glyph(i.public_ip) for i in instances], "PUBLIC IP"),
        )


@dataclass(frozen=True)
class Layout:
    columns: Columns
    show_type: bool
    full_date: bool

    @classmethod
    def fit(cls, instances: list[Instance], names: list[str], width: int) -> Layout:
        """Shed the least load-bearing field first as the terminal narrows.

        Instance type goes before the launch year: it is useful context, but you
        pick a node by name, state, id and address. Abbreviating the type instead
        of dropping it only saves four columns, which is not enough to matter.
        """
        columns = Columns.fit(instances, names)
        base = 5 + columns.name + columns.iid + columns.private + columns.public
        available = max(0, width - 1)
        for show_type, full_date in ((True, True), (False, True), (False, False)):
            need = base + (columns.itype if show_type else 0) + (16 if full_date else 11)
            if need <= available:
                return cls(columns, show_type, full_date)
        return cls(columns, False, False)


def draw_panel(stdscr, state: PickerState, countdown: int, width: int, height: int,
               C: dict[str, int]) -> None:
    counts: dict[str, int] = {}
    roles: dict[str, int] = {}
    for inst in state.instances:
        counts[inst.state] = counts.get(inst.state, 0) + 1
        roles[inst.role] = roles.get(inst.role, 0) + 1
    total = len(state.instances)

    # Corners and rules belong to the frame; only the words carry the accent.
    brand = "SimpleK3s"
    context = f"{state.nickname} · {state.region}"
    chrome = len("╭─ ") + len(brand) + 2 + len(context) + len(" ─╮")
    fill = max(0, width - 1 - chrome)
    put(stdscr, 0, [
        ("╭─ ", C["frame"]),
        (brand, C["title"]),
        (" ", 0),
        ("─" * fill, C["frame"]),
        (" ", 0),
        (context, C["title"]),
        (" ─╮", C["frame"]),
    ], width, height)

    put(stdscr, 1, panel_line([("│", C["frame"])], width, C), width, height)

    # The panel must fit or its right border gets clipped and the box looks
    # broken, so the meter and the labels give ground as the terminal narrows.
    cells = max(8, min(METER_CELLS, width - 62))
    verbose = width >= 92

    summary: list[Segment] = [("│  ", C["frame"]), ("Nodes ", C["dim"]),
                              (f"{total:<4}", C["white"])]
    summary += meter(counts, total, cells, C)
    summary.append(("  ", 0))
    for name in STATE_ORDER:
        if counts.get(name):
            summary.append(("● ", C[STATE_COLOR.get(name, "white")]))
            summary.append((f"{counts[name]} {name}  " if verbose else f"{counts[name]}  ",
                            C["dim"]))
    put(stdscr, 2, panel_line(summary, width, C), width, height)

    role_line: list[Segment] = [("│  ", C["frame"]), ("Roles ", C["dim"]), ("     ", 0)]
    for role in ("control-plane", "agent", "karpenter", "node"):
        if roles.get(role):
            role_line.append((f"{role if verbose else ROLE_SHORT[role]} ", C[ROLE_COLOR[role]]))
            role_line.append((f"{roles[role]}    ", C["dim"]))
    # The dot alternates once per redraw, so a live picker is visibly ticking
    # even while the countdown digit is unchanged. Width-2 keeps the seconds
    # column from shifting as it drops from 10s to 9s.
    pulse = "●" if countdown % 2 == 0 else "○"
    clock: list[Segment] = [(f"{pulse} refresh in: {countdown:>2}s  ", C["dim"])]
    put(stdscr, 3, panel_line(role_line, width, C, trailer=clock), width, height)

    put(stdscr, 4, panel_line([("│", C["frame"])], width, C), width, height)
    put(stdscr, 5, [("╰" + "─" * max(0, width - 3) + "╯", C["frame"])], width, height)


def draw_rail(stdscr, layout: Layout, width: int, height: int, C: dict[str, int]) -> None:
    cols = layout.columns
    text = f"     {'NAME':<{cols.name}}{'INSTANCE ID':<{cols.iid}}"
    if layout.show_type:
        text += f"{'TYPE':<{cols.itype}}"
    text += f"{'PRIVATE IP':<{cols.private}}{'PUBLIC IP':<{cols.public}}LAUNCHED"
    put(stdscr, PANEL_HEIGHT, [(text.ljust(max(0, width - 1)), C["rail"])], width, height,
        override=C["rail"])


def instance_segments(inst: Instance, name: str, layout: Layout, selected: bool,
                      C: dict[str, int]) -> list[Segment]:
    cols = layout.columns
    segments: list[Segment] = [
        (" ▸ " if selected else "   ", C["cyan"]),
        ("● ", C[STATE_COLOR.get(inst.state, "white")]),
        (name[: cols.name].ljust(cols.name), C[ROLE_COLOR[inst.role]]),
        (inst.instance_id.ljust(cols.iid), C["dim"]),
    ]
    if layout.show_type:
        segments.append((inst.instance_type.ljust(cols.itype), C["white"]))
    segments += [
        (glyph(inst.private_ip).ljust(cols.private), C["white"]),
        (glyph(inst.public_ip).ljust(cols.public), C["dim"]),
        (inst.launch if layout.full_date else inst.launch_short, C["dim"]),
    ]
    return segments


def draw_keybar(stdscr, width: int, height: int, C: dict[str, int]) -> None:
    segments: list[Segment] = [(" ", 0)]
    for key, label in (("↑↓", "move"), ("⏎", "connect"), ("r", "refresh"), ("q", "quit")):
        segments.append((f" {key} ", C["key"]))
        segments.append((f" {label}    ", C["dim"]))
    put(stdscr, height - 1, segments, width, height)


def draw(stdscr, state: PickerState, countdown: int, top: int, C: dict[str, int]) -> int:
    stdscr.erase()
    height, width = stdscr.getmaxyx()
    names = display_names(state.instances)
    layout = Layout.fit(state.instances, list(names.values()), width)

    draw_panel(stdscr, state, countdown, width, height, C)
    draw_rail(stdscr, layout, width, height, C)
    draw_keybar(stdscr, width, height, C)

    if state.error:
        put(stdscr, height - 2, [(f" ✖ {state.error}", C["red"] | curses.A_BOLD)], width, height)
    elif state.message:
        put(stdscr, height - 2, [(f" ▲ {state.message}", C["warn"])], width, height)

    body_top = PANEL_HEIGHT + 1
    body_height = max(1, height - body_top - FOOTER_HEIGHT)

    if not state.instances:
        put(stdscr, body_top, [("   (no instances found)", C["dim"])], width, height)
        stdscr.refresh()
        return 0

    rows: list[tuple[str, object]] = []
    previous_az = None
    for index, inst in enumerate(state.instances):
        if inst.az != previous_az:
            rows.append(("az", inst.az))
            previous_az = inst.az
        rows.append(("instance", index))

    selected_row = next(
        (n for n, (kind, payload) in enumerate(rows)
         if kind == "instance" and payload == state.selected),
        0,
    )
    if selected_row < top:
        top = selected_row
    elif selected_row >= top + body_height:
        top = selected_row - body_height + 1
    top = max(0, min(top, max(0, len(rows) - body_height)))

    for offset in range(body_height):
        index = top + offset
        if index >= len(rows):
            break
        kind, payload = rows[index]
        y = body_top + offset
        if kind == "az":
            label = f" ── {payload} "
            rule = "─" * max(0, width - 1 - len(label))
            put(stdscr, y, [(label, C["section"]), (rule, C["frame"])], width, height)
            continue
        inst = state.instances[payload]
        chosen = payload == state.selected
        put(stdscr, y,
            instance_segments(inst, names[inst.instance_id], layout, chosen, C),
            width, height, override=C["select"] if chosen else None)

    stdscr.refresh()
    return top


# ─── Interaction ─────────────────────────────────────────────────────────────

def picker(stdscr, state: PickerState) -> Instance | None:
    curses.curs_set(0)
    stdscr.timeout(TICK_MS)
    colors = init_colors()
    top = 0
    while True:
        now = time.monotonic()
        if now - state.last_refresh >= state.refresh_interval:
            if not state.demo:
                try:
                    state.instances = fetch_instances(state.region, state.profile, state.nickname)
                    state.error = None
                except (RuntimeError, json.JSONDecodeError, OSError) as exc:
                    # Keep the last good table on screen rather than dropping out
                    state.error = str(exc)
                state.selected = min(state.selected, max(0, len(state.instances) - 1))
            # Demo makes no API call but still restarts the clock, so the
            # countdown and its pulse behave exactly as they do in real use.
            state.last_refresh = now

        # ceil, floored at 1: counting down to "0s" reads as stalled, and the
        # value is only ever shown between two real refreshes anyway.
        remaining = state.refresh_interval - (time.monotonic() - state.last_refresh)
        countdown = max(1, math.ceil(remaining))
        top = draw(stdscr, state, countdown, top, colors)

        key = stdscr.getch()
        if key == -1:  # tick
            continue
        if key in (curses.KEY_UP, ord("k")):
            state.selected = max(0, state.selected - 1)
            state.message = None
        elif key in (curses.KEY_DOWN, ord("j")):
            state.selected = min(len(state.instances) - 1, state.selected + 1)
            state.message = None
        elif key in (ord("r"), ord("R")):
            state.last_refresh = 0.0
        elif key in (ord("q"), ord("Q")):
            return None
        elif key in (curses.KEY_ENTER, 10, 13):
            if state.instances:
                candidate = state.instances[state.selected]
                # Refuse here rather than letting SSM fail opaquely later; this
                # matches ssm_connect.sh's check on an explicit --instance-id.
                if candidate.state != "running":
                    state.message = (
                        f"{candidate.instance_id} is {candidate.state} — "
                        "only running instances can be connected to"
                    )
                    continue
                return candidate
        elif key == curses.KEY_RESIZE:
            top = 0  # geometry changed; recompute from the top on the next draw


def run_picker(state: PickerState) -> Instance | None:
    """Drive curses against the terminal even when stdout/stdin are redirected.

    The chosen id goes to the real stdout, so the caller can capture it while
    the interface still draws on /dev/tty.
    """
    try:
        tty_out = os.open("/dev/tty", os.O_WRONLY)
        tty_in = os.open("/dev/tty", os.O_RDONLY)
    except OSError as exc:
        raise RuntimeError(
            "no terminal available for the picker; pass --instance-id instead"
        ) from exc

    sys.stdout.flush()
    saved_out, saved_in = os.dup(1), os.dup(0)
    try:
        os.dup2(tty_out, 1)
        os.dup2(tty_in, 0)
        return curses.wrapper(picker, state)
    finally:
        os.dup2(saved_out, 1)
        os.dup2(saved_in, 0)
        for handle in (saved_out, saved_in, tty_out, tty_in):
            os.close(handle)


# ─── Entry point ─────────────────────────────────────────────────────────────

def main(argv: list[str] | None = None) -> int:
    locale.setlocale(locale.LC_ALL, "")

    parser = argparse.ArgumentParser(
        description="Pick an EC2 instance from a SimpleK3s cluster.",
    )
    parser.add_argument("--region", help="AWS region")
    parser.add_argument("--profile", help="AWS CLI profile")
    parser.add_argument("--nickname", help="cluster nickname tag")
    parser.add_argument("--refresh-interval", type=int, default=REFRESH_INTERVAL,
                        help=f"seconds between refreshes (default: {REFRESH_INTERVAL})")
    parser.add_argument("--list", action="store_true",
                        help="print instances as TSV and exit, without the picker")
    parser.add_argument("--table", action="store_true",
                        help="print instances as a formatted table and exit")
    parser.add_argument("--demo", action="store_true",
                        help="use built-in fixture data; makes no AWS calls")
    args = parser.parse_args(argv)

    if args.demo:
        instances = demo_instances()
        region, profile, nickname = "us-west-2", "default", "prodcluster"
    else:
        missing = [f"--{n}" for n in ("region", "profile", "nickname") if not getattr(args, n)]
        if missing:
            parser.error(f"{', '.join(missing)} required (or use --demo)")
        region, profile, nickname = args.region, args.profile, args.nickname
        try:
            instances = fetch_instances(region, profile, nickname)
        except (RuntimeError, json.JSONDecodeError, OSError) as exc:
            print(f"Error: {exc}", file=sys.stderr)
            return 1

    if args.list:
        for inst in instances:
            print(inst.as_tsv())
        return 0

    if args.table:
        for line in format_table(instances):
            print(line)
        return 0

    if not instances:
        print(f"Error: no instances found for cluster '{nickname}' in {region}.", file=sys.stderr)
        return 1

    state = PickerState(
        region=region, profile=profile, nickname=nickname,
        refresh_interval=args.refresh_interval, demo=args.demo,
        instances=instances,
        # The table is already loaded; start the clock so entering the picker
        # does not immediately fire a second describe-instances call.
        last_refresh=time.monotonic(),
    )

    try:
        chosen = run_picker(state)
    except RuntimeError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    if chosen is None:
        print("Cancelled.", file=sys.stderr)
        return 130

    print(chosen.instance_id)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("Cancelled.", file=sys.stderr)
        sys.exit(130)
