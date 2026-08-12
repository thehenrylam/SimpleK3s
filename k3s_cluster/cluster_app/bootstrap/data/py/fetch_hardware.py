#!/usr/bin/env python3

# Builtin Modules
import importlib.util
import os
import shutil
import time

# NOTE: stdlib only, deliberately.
#
# This probe used to import psutil, which meant the bootstrap tree carried a
# uv-managed .venv (~50 MB / 912 files) that existed for six calls in this one
# file. Everything below reads /proc directly or uses an exact stdlib
# equivalent, so the node needs nothing beyond the system python3 that the
# Debian AMI already ships.
#
# That matters beyond disk: node_sync-* has to be able to REPAIR the bootstrap
# directory, so nothing on that path may depend on an interpreter environment
# living inside the directory being repaired. Helper scripts that genuinely
# need a third-party package declare it inline (PEP 723) and run under `uv run`
# — see examples/standard_deployment/scripts/ssm_pick_instance.py — which
# resolves into uv's cache rather than into this tree.
#
# The formulas below were matched empirically against psutil 7.2.2 on a live
# node so the emitted numbers stay comparable with previously captured
# answersheets.

_dir = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "fetch_UTILITIES", os.path.join(_dir, "fetch_UTILITIES.py")
)
_utils = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_utils)
emit = _utils.emit


# HELPER FUNCTION: Convert B -> MB (Round to 2 decimal places)
def convert_bytes_to_megabytes(num):
    return round(num / (1024 * 1024), 2)


# HELPER FUNCTION: percentage, guarding against a zero denominator (a node with
# swap disabled has SwapTotal=0, and psutil reports 0.0 there rather than erroring).
def percent_of(part, whole):
    if whole <= 0:
        return 0.0
    return round(part / whole * 100, 1)


# HELPER FUNCTION: /proc/meminfo as a dict of name -> bytes.
# Every value in that file is reported in kB regardless of the unit column.
def read_meminfo():
    meminfo = dict()
    with open("/proc/meminfo") as fh:
        for line in fh:
            name, _, rest = line.partition(":")
            fields = rest.split()
            if fields:
                meminfo[name] = int(fields[0]) * 1024
    return meminfo


# HELPER FUNCTION: per-core (busy, total) jiffy counters from /proc/stat.
#
# Field order is: user nice system idle iowait irq softirq steal guest guest_nice.
# guest/guest_nice are ALREADY included in user/nice respectively, so they are
# subtracted out before summing — counting them twice inflates the total and
# understates the busy percentage.
def read_cpu_times():
    per_core = []
    with open("/proc/stat") as fh:
        for line in fh:
            if not line.startswith("cpu"):
                continue
            fields = line.split()
            # "cpu" alone is the aggregate across all cores; we want "cpu0", "cpu1", ...
            if fields[0] == "cpu":
                continue
            values = [int(v) for v in fields[1:]]
            # Pad so a kernel reporting fewer columns does not IndexError
            values += [0] * (10 - len(values))
            user, nice, system, idle, iowait, irq, softirq, steal, guest, guest_nice = values[:10]
            user -= guest
            nice -= guest_nice
            idle_all = idle + iowait
            total = user + nice + system + idle_all + irq + softirq + steal
            per_core.append((total - idle_all, total))
    return per_core


# Fetch CPU usage (Represented by %)
def fetch_cpu_usage():
    # Poll the CPU statistics (Takes 2 snapshots with a 0.33s interval for accuracy)
    before = read_cpu_times()
    time.sleep(0.33)
    after = read_cpu_times()

    # Format the data in a JSON friendly format.
    #
    # strict=False deliberately: if the core count changes between the two reads
    # (CPU hotplug/offlining), truncating to the cores seen in both samples
    # reports slightly fewer cores, whereas strict=True would raise and take the
    # whole hardware probe — memory and disk included — down with it.
    output = dict()
    for i, ((busy0, total0), (busy1, total1)) in enumerate(zip(before, after, strict=False)):
        total_delta = total1 - total0
        busy_delta = busy1 - busy0
        output[i] = percent_of(busy_delta, total_delta)
    return output


# Fetch CPU load (Represented by %)
def fetch_cpu_load():
    # Poll the LoadAvg statistics
    cpu_load_avg = os.getloadavg()
    # Get the CPU count
    cpu_count = os.cpu_count()

    # percentage representation
    cpu_load_in_pct = [x / cpu_count * 100 for x in cpu_load_avg]

    output = {
        "1 min": round(cpu_load_in_pct[0], 2),
        "5 min": round(cpu_load_in_pct[1], 2),
        "15 min": round(cpu_load_in_pct[2], 2),
    }
    return output


# Fetch CPU status
def fetch_cpu():
    cpu_load = fetch_cpu_load()
    cpu_usage = fetch_cpu_usage()

    output = {"load": cpu_load, "usage": cpu_usage}
    return output


# Fetch Memory status (RAM + SWAP)
def fetch_memory():
    meminfo = read_meminfo()

    # Get RAM data and represent it in JSON friendly format.
    #
    # "used" is total - MemAvailable, matching what psutil 7.2.2 reports here.
    # Note this is NOT the `free` command's used column (total - free - buff/cache):
    # MemAvailable is the kernel's own estimate of what a new allocation could
    # actually get, which counts reclaimable cache as available. It is the more
    # honest number for "how close is this node to memory pressure".
    ram_total = meminfo["MemTotal"]
    ram_available = meminfo["MemAvailable"]
    ram = {
        "usage": percent_of(ram_total - ram_available, ram_total),
        # Report available memory as "free" — what users normally think of as free
        "free (MB)": convert_bytes_to_megabytes(ram_available),
        "used (MB)": convert_bytes_to_megabytes(ram_total - ram_available),
        "total (MB)": convert_bytes_to_megabytes(ram_total),
    }

    # Get SWAP data and represent it in JSON friendly format
    swap_total = meminfo["SwapTotal"]
    swap_free = meminfo["SwapFree"]
    swap_used = swap_total - swap_free
    swap = {
        "usage": percent_of(swap_used, swap_total),
        "free (MB)": convert_bytes_to_megabytes(swap_free),
        "used (MB)": convert_bytes_to_megabytes(swap_used),
        "total (MB)": convert_bytes_to_megabytes(swap_total),
    }
    output = {"ram": ram, "swap": swap}
    return output


# Fetch Disk status
def fetch_disk():
    # ASSUMPTION: The main drive has the mountpoint of "/"
    # (Which should be the case for Linux machines, which is our target platform)
    #
    # shutil.disk_usage is statvfs underneath with the same definitions psutil
    # uses: total = f_blocks, free = f_bavail (excludes root-reserved blocks),
    # used = f_blocks - f_bfree.
    disk_data = shutil.disk_usage("/")

    # Percentage is used / (used + free), NOT used / total. The difference is the
    # root-reserved blocks, which are unusable by ordinary processes — this is the
    # same convention `df` prints, so the number matches what an operator sees on
    # the node.
    output = {
        "usage": percent_of(disk_data.used, disk_data.used + disk_data.free),
        "free (MB)": convert_bytes_to_megabytes(disk_data.free),
        "used (MB)": convert_bytes_to_megabytes(disk_data.used),
        "total (MB)": convert_bytes_to_megabytes(disk_data.total),
    }
    return output


# === THE MAIN FUNCTION ===
def fetch_hardware():
    cpu_status = fetch_cpu()
    memory_status = fetch_memory()
    disk_status = fetch_disk()
    output = {"cpu": cpu_status, "memory": memory_status, "disk": disk_status}
    return output


if __name__ == "__main__":
    output = fetch_hardware()
    emit(output)
