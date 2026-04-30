#!/usr/bin/env python3
"""Convert InfluxDB data.json to line protocol and Prometheus exposition format.

Usage: convert-datajson.py <input.json> <output_dir>
Creates: <output_dir>/influx.line  (nanosecond precision)
         <output_dir>/vm.prom      (millisecond precision)
"""

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


def main():
    input_file = sys.argv[1]
    output_dir = Path(sys.argv[2])

    with open(input_file) as f:
        data = json.load(f)
    values = data["results"][0]["series"][0]["values"]

    influx_lines = []
    prom_lines = []

    for row in values:
        ts_str, dl, ul, ping = row
        m = re.match(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\.?(\d*)Z", ts_str)
        dt = datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S").replace(
            tzinfo=timezone.utc
        )
        frac = m.group(2) if m.group(2) else "0"

        # InfluxDB line protocol (nanosecond precision)
        sec_ns = int(dt.timestamp()) * 1_000_000_000
        frac_ns = int(frac.ljust(9, "0")[:9])
        ts_ns = sec_ns + frac_ns
        influx_lines.append(
            f"speedtest download_bandwidth={dl}i,"
            f"upload_bandwidth={ul}i,"
            f"ping_latency={ping} {ts_ns}"
        )

        # Prometheus exposition format (millisecond precision)
        ts_ms = int(dt.timestamp() * 1000)
        frac_ms = int(frac.ljust(9, "0")[:9]) // 1_000_000
        ts_ms += frac_ms
        prom_lines.append(f"speedtest_download_bandwidth {dl} {ts_ms}")
        prom_lines.append(f"speedtest_upload_bandwidth {ul} {ts_ms}")
        prom_lines.append(f"speedtest_ping_latency {ping} {ts_ms}")

    (output_dir / "influx.line").write_text("\n".join(influx_lines) + "\n")
    print(f"   {len(influx_lines)} InfluxDB line protocol entries")

    (output_dir / "vm.prom").write_text("\n".join(prom_lines) + "\n")
    print(f"   {len(prom_lines)} Prometheus metric lines")


if __name__ == "__main__":
    main()
