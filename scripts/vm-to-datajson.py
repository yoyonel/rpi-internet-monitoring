#!/usr/bin/env python3
"""Transform VictoriaMetrics JSONL export into InfluxDB-compatible data.json.

Reads three JSONL files (one per metric) exported via the VM /api/v1/export
endpoint and produces the same JSON structure that InfluxDB ``influx -format json``
emits.  This lets publish-gh-pages.sh swap the TSDB backend without changing the
frontend contract.

Usage:
    python3 scripts/vm-to-datajson.py <dir>

Where <dir> contains dl.jsonl, ul.jsonl and ping.jsonl (any may be empty).
Output goes to stdout.
"""

import json
import os
import sys
from datetime import datetime, timezone


def parse_export(path):
    """Parse a VM /api/v1/export JSONL file into {timestamp_ms: value}."""
    merged = {}
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        return merged
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            data = json.loads(line)
            for ts, val in zip(data.get("timestamps", []), data.get("values", [])):
                merged[ts] = val
    return merged


def to_influxdb_json(dl_map, ul_map, ping_map):
    """Build InfluxDB-compatible JSON from per-metric maps."""
    all_ts = sorted(set(dl_map) | set(ul_map) | set(ping_map))

    if not all_ts:
        return {"results": [{"series": []}]}

    values = []
    for ts in all_ts:
        dl = dl_map.get(ts)
        ul = ul_map.get(ts)
        ping = ping_map.get(ts)
        if dl is None and ul is None and ping is None:
            continue
        dt = datetime.fromtimestamp(ts / 1000, tz=timezone.utc)
        ms = ts % 1000
        time_str = dt.strftime("%Y-%m-%dT%H:%M:%S") + (
            f".{ms:03d}000000Z" if ms else "Z"
        )
        values.append([time_str, dl, ul, ping])

    return {
        "results": [
            {
                "series": [
                    {
                        "name": "speedtest",
                        "columns": [
                            "time",
                            "download_bandwidth",
                            "upload_bandwidth",
                            "ping_latency",
                        ],
                        "values": values,
                    }
                ]
            }
        ]
    }


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <dir>", file=sys.stderr)
        sys.exit(2)

    tmpdir = sys.argv[1]
    dl_map = parse_export(os.path.join(tmpdir, "dl.jsonl"))
    ul_map = parse_export(os.path.join(tmpdir, "ul.jsonl"))
    ping_map = parse_export(os.path.join(tmpdir, "ping.jsonl"))

    result = to_influxdb_json(dl_map, ul_map, ping_map)
    json.dump(result, sys.stdout)


if __name__ == "__main__":
    main()
