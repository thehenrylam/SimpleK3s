"""Host metrics, read straight from /proc and statvfs.

STDLIB ONLY, DELIBERATELY. psutil would be one dependency, but the sync path has
to be able to REPAIR the bootstrap directory, so nothing on it may rely on an
interpreter environment living inside the directory being repaired. The formulas
below were matched empirically against psutil 7.2.2 on a live node so the numbers
stay comparable with previously captured answer sheets.

These are FACTS. Nothing here decides whether a reading is acceptable — a disk at
86% is a number, and what to do about it belongs to whatever reads the report.
"""

import os
import shutil
import time

# Two /proc/stat snapshots this far apart. Long enough to be a meaningful sample,
# short enough that it does not dominate the run's latency on every node.
SAMPLE_SECONDS = 0.33


def megabytes(count):
    return round(count / (1024 * 1024), 2)


def percent_of(part, whole):
    """Guarded: a node with swap disabled reports SwapTotal=0."""
    if whole <= 0:
        return 0.0
    return round(part / whole * 100, 1)


def read_meminfo(path="/proc/meminfo"):
    """/proc/meminfo as name -> bytes. Every value there is in kB."""
    values = {}
    with open(path) as handle:
        for line in handle:
            name, _, rest = line.partition(":")
            fields = rest.split()
            if fields:
                values[name] = int(fields[0]) * 1024
    return values


def read_cpu_times(path="/proc/stat"):
    """Per-core (busy, total) jiffy counters.

    Field order: user nice system idle iowait irq softirq steal guest guest_nice.
    guest and guest_nice are ALREADY counted inside user and nice, so they are
    subtracted out — counting them twice inflates total and understates busy.
    """
    per_core = []
    with open(path) as handle:
        for line in handle:
            if not line.startswith("cpu"):
                continue
            fields = line.split()
            # "cpu" alone is the aggregate; we want cpu0, cpu1, ...
            if fields[0] == "cpu":
                continue
            values = [int(v) for v in fields[1:]]
            # Pad so a kernel reporting fewer columns cannot IndexError.
            values += [0] * (10 - len(values))
            user, nice, system, idle, iowait, irq, softirq, steal, guest, guest_nice = values[:10]
            user -= guest
            nice -= guest_nice
            idle_all = idle + iowait
            total = user + nice + system + idle_all + irq + softirq + steal
            per_core.append((total - idle_all, total))
    return per_core


def cpu_usage(before=None, after=None):
    """Busy percentage per core between two snapshots."""
    if before is None:
        before = read_cpu_times()
        time.sleep(SAMPLE_SECONDS)
        after = read_cpu_times()
    output = {}
    # strict=False deliberately: if the core count changes between reads (CPU
    # hotplug), truncating to the cores seen in both is a slightly short answer,
    # where strict=True would raise and take memory and disk down with it.
    for index, ((busy0, total0), (busy1, total1)) in enumerate(zip(before, after, strict=False)):
        output[index] = percent_of(busy1 - busy0, total1 - total0)
    return output


def cpu_load(load=None, cores=None):
    """Load average as a percentage of total CPU capacity."""
    load = os.getloadavg() if load is None else load
    cores = os.cpu_count() if cores is None else cores
    if not cores:
        return {"1 min": 0.0, "5 min": 0.0, "15 min": 0.0}
    labels = ("1 min", "5 min", "15 min")
    return {label: round(value / cores * 100, 2) for label, value in zip(labels, load, strict=True)}


def memory(meminfo=None):
    info = read_meminfo() if meminfo is None else meminfo
    ram_total = info["MemTotal"]
    ram_available = info["MemAvailable"]
    # "used" is total - MemAvailable, matching psutil. NOT the `free` command's
    # used column: MemAvailable is the kernel's estimate of what a new allocation
    # could actually get, counting reclaimable cache as available — the more
    # honest answer to "how close is this node to memory pressure".
    ram = {
        "usage": percent_of(ram_total - ram_available, ram_total),
        "free (MB)": megabytes(ram_available),
        "used (MB)": megabytes(ram_total - ram_available),
        "total (MB)": megabytes(ram_total),
    }
    swap_total = info["SwapTotal"]
    swap_free = info["SwapFree"]
    swap = {
        "usage": percent_of(swap_total - swap_free, swap_total),
        "free (MB)": megabytes(swap_free),
        "used (MB)": megabytes(swap_total - swap_free),
        "total (MB)": megabytes(swap_total),
    }
    return {"ram": ram, "swap": swap}


def disk(usage=None):
    """Root filesystem. statvfs underneath, with psutil's definitions."""
    usage = shutil.disk_usage("/") if usage is None else usage
    # used / (used + free), NOT used / total. The difference is the root-reserved
    # blocks, unusable by ordinary processes — this is what `df` prints, so the
    # number matches what an operator sees on the node.
    return {
        "usage": percent_of(usage.used, usage.used + usage.free),
        "free (MB)": megabytes(usage.free),
        "used (MB)": megabytes(usage.used),
        "total (MB)": megabytes(usage.total),
    }


def snapshot():
    return {
        "cpu": {"load": cpu_load(), "usage": cpu_usage()},
        "memory": memory(),
        "disk": disk(),
    }
