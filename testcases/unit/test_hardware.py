"""Host metrics read from /proc.

These formulas were matched against psutil so captured answer sheets stay
comparable, so the arithmetic is pinned rather than left to drift.
"""

import types

from sk3s_verify import hardware


def test_percent_of_guards_a_zero_denominator():
    """A node with swap disabled reports SwapTotal=0; dividing would raise."""
    assert hardware.percent_of(0, 0) == 0.0


def test_percent_of_is_rounded_to_one_decimal():
    assert hardware.percent_of(1, 3) == 33.3


def test_megabytes_uses_binary_units():
    assert hardware.megabytes(1024 * 1024) == 1.0


def test_meminfo_values_are_converted_from_kb_to_bytes(tmp_path):
    path = tmp_path / "meminfo"
    path.write_text("MemTotal:        4096 kB\nMemAvailable:    1024 kB\n")
    assert hardware.read_meminfo(str(path)) == {"MemTotal": 4194304, "MemAvailable": 1048576}


def test_cpu_times_skips_the_aggregate_row(tmp_path):
    path = tmp_path / "stat"
    path.write_text(
        "cpu  100 0 0 100 0 0 0 0 0 0\n"
        "cpu0 10 0 0 90 0 0 0 0 0 0\n"
        "cpu1 20 0 0 80 0 0 0 0 0 0\n"
        "intr 12345\n"
    )
    assert len(hardware.read_cpu_times(str(path))) == 2


def test_cpu_times_does_not_double_count_guest(tmp_path):
    """guest and guest_nice are already inside user and nice.

    Counting them again inflates total and understates the busy percentage.
    """
    path = tmp_path / "stat"
    # user=50 (of which guest=50), idle=50. All the "user" time is guest time,
    # so busy is 0 and total is 50.
    path.write_text("cpu0 50 0 0 50 0 0 0 0 50 0\n")
    (busy, total) = hardware.read_cpu_times(str(path))[0]
    assert (busy, total) == (0, 50)


def test_cpu_usage_is_computed_between_two_snapshots():
    before = [(0, 0), (0, 0)]
    after = [(50, 100), (25, 100)]
    assert hardware.cpu_usage(before, after) == {0: 50.0, 1: 25.0}


def test_cpu_usage_tolerates_a_changing_core_count():
    """CPU hotplug must not take memory and disk down with it."""
    assert hardware.cpu_usage([(0, 0)], [(50, 100), (10, 100)]) == {0: 50.0}


def test_cpu_load_is_a_percentage_of_total_capacity():
    assert hardware.cpu_load(load=(2.0, 1.0, 0.5), cores=2) == {
        "1 min": 100.0,
        "5 min": 50.0,
        "15 min": 25.0,
    }


def test_cpu_load_survives_an_unknown_core_count(monkeypatch):
    """os.cpu_count() can return None; dividing by it would raise."""
    monkeypatch.setattr(hardware.os, "cpu_count", lambda: None)
    assert hardware.cpu_load(load=(1.0, 1.0, 1.0)) == {"1 min": 0.0, "5 min": 0.0, "15 min": 0.0}


def test_memory_used_is_total_minus_available_not_total_minus_free():
    """MemAvailable counts reclaimable cache, which is the honest headroom."""
    info = {
        "MemTotal": 1000 * 1024 * 1024,
        "MemAvailable": 250 * 1024 * 1024,
        "SwapTotal": 0,
        "SwapFree": 0,
    }
    ram = hardware.memory(info)["ram"]
    assert ram["used (MB)"] == 750.0
    assert ram["free (MB)"] == 250.0
    assert ram["usage"] == 75.0


def test_memory_reports_zero_usage_when_swap_is_disabled():
    info = {
        "MemTotal": 1024 * 1024,
        "MemAvailable": 1024 * 1024,
        "SwapTotal": 0,
        "SwapFree": 0,
    }
    assert hardware.memory(info)["swap"] == {
        "usage": 0.0,
        "free (MB)": 0.0,
        "used (MB)": 0.0,
        "total (MB)": 0.0,
    }


def test_disk_usage_excludes_root_reserved_blocks():
    """used / (used + free), matching what `df` prints on the node."""
    usage = types.SimpleNamespace(
        total=100 * 1024 * 1024, used=50 * 1024 * 1024, free=50 * 1024 * 1024
    )
    assert hardware.disk(usage)["usage"] == 50.0


def test_disk_usage_is_not_used_over_total():
    """total includes reserved blocks, so it would understate the reading."""
    usage = types.SimpleNamespace(
        total=100 * 1024 * 1024, used=45 * 1024 * 1024, free=45 * 1024 * 1024
    )
    assert hardware.disk(usage)["usage"] == 50.0
