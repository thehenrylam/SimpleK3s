#!/usr/bin/env python3

# Builtin Modules
import json

# Installed Modules
import psutil


# HELPER FUNCTION: Convert B -> MB (Round to 2 decimal places)
def convert_bytes_to_megabytes(num):
    return round(num / (1024 * 1024), 2)


# Fetch CPU usage (Represented by %)
def fetch_cpu_usage():
    # Poll the CPU statistics (Takes 2 snapshots with a 0.33s interval for accuracy)
    cpu_usage_per_core = list(psutil.cpu_percent(interval=0.33, percpu=True))

    # Format the data in a JSON friendly format
    output = dict()
    for i, usage in enumerate(cpu_usage_per_core):
        output[i] = round(usage, 2)
    return output


# Fetch CPU load (Represented by %)
def fetch_cpu_load():
    # Poll the LoadAvg statistics
    cpu_load_avg = psutil.getloadavg()
    # Get the CPU count
    cpu_count = psutil.cpu_count()

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
    # Get RAM data and represent it in JSON friendly format
    ram_data = psutil.virtual_memory()
    ram = {
        "usage": ram_data.percent,
        # Report available memory as "free" — what users normally think of as free
        "free (MB)": convert_bytes_to_megabytes(ram_data.available),
        "used (MB)": convert_bytes_to_megabytes(ram_data.used),
        "total (MB)": convert_bytes_to_megabytes(ram_data.total),
    }

    # Get SWAP data and represent it in JSON friendly format
    swap_data = psutil.swap_memory()
    swap = {
        "usage": swap_data.percent,
        "free (MB)": convert_bytes_to_megabytes(swap_data.free),
        "used (MB)": convert_bytes_to_megabytes(swap_data.used),
        "total (MB)": convert_bytes_to_megabytes(swap_data.total),
    }
    output = {"ram": ram, "swap": swap}
    return output


# Fetch Disk status
def fetch_disk():
    # ASSUMPTION: The main drive has the mountpoint of "/"
    # (Which should be the case for Linux machines, which is our target platform)
    disk_data = psutil.disk_usage("/")

    print(disk_data)

    output = {
        "usage": disk_data.percent,
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
    print(json.dumps(output, indent=4))
