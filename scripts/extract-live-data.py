#!/usr/bin/env python3
"""Extract RAW_DATA and ALERTS from the live GitHub Pages HTML.

Usage: python3 scripts/extract-live-data.py <live_html> <output_dir>

Writes:
  <output_dir>/data.json   — speedtest data (RAW_DATA object)
  <output_dir>/alerts.json — alerts array (ALERTS)
"""

import json
import re
import sys


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <live_html> <output_dir>", file=sys.stderr)
        sys.exit(1)

    live_html_path = sys.argv[1]
    output_dir = sys.argv[2]

    with open(live_html_path) as f:
        html = f.read()

    m = re.search(r"(?:var|const)\s+RAW_DATA\s*=\s*({.*?});", html, re.DOTALL)
    if not m:
        print("ERROR: Could not extract RAW_DATA from live page", file=sys.stderr)
        sys.exit(1)
    with open(f"{output_dir}/data.json", "w") as f:
        f.write(m.group(1))

    m2 = re.search(r"(?:var|const)\s+ALERTS\s*=\s*(\{.*?\}|\[.*?\]);", html, re.DOTALL)
    if not m2:
        print("ERROR: Could not extract ALERTS from live page", file=sys.stderr)
        sys.exit(1)
    alerts_raw = m2.group(1)
    with open(f"{output_dir}/alerts.json", "w") as f:
        f.write(alerts_raw)

    data = json.loads(m.group(1))
    pts = len(data.get("results", [{}])[0].get("series", [{}])[0].get("values", []))
    alerts_parsed = json.loads(alerts_raw)
    # Support both {alerts: [...], lastEvaluation: ...} and legacy [...] format
    if isinstance(alerts_parsed, dict):
        alert_count = len(alerts_parsed.get("alerts", []))
    else:
        alert_count = len(alerts_parsed)
    print(f"  → {pts} data points, {alert_count} alerts extracted")


if __name__ == "__main__":
    main()
