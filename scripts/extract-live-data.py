#!/usr/bin/env python3
"""Extract speedtest data and alerts from a live site directory or HTML.

Supports two modes:
  1. External JSON (current): looks for data.json / alerts.json next to the
     downloaded HTML file (same directory).
  2. Inline fallback (legacy): extracts RAW_DATA and ALERTS from <script>
     tags embedded in the HTML.

Usage: python3 scripts/extract-live-data.py <live_html> <output_dir>

Writes:
  <output_dir>/data.json   — speedtest data
  <output_dir>/alerts.json — alerts data
"""

import json
import re
import sys
from pathlib import Path


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <live_html> <output_dir>", file=sys.stderr)
        sys.exit(1)

    live_html_path = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])
    source_dir = live_html_path.parent

    with open(live_html_path) as f:
        html = f.read()

    data_json = None
    alerts_json = None

    # Strategy 1: look for JSON files next to the HTML (new format)
    data_file = source_dir / "data.json"
    alerts_file = source_dir / "alerts.json"

    if data_file.exists():
        data_json = data_file.read_text()
    if alerts_file.exists():
        alerts_json = alerts_file.read_text()

    # Strategy 2: extract from inline <script> tags (legacy format)
    if not data_json:
        m = re.search(r"(?:var|const)\s+RAW_DATA\s*=\s*({.*?});", html, re.DOTALL)
        if not m:
            print(
                "ERROR: Could not find data (no data.json, no inline RAW_DATA)",
                file=sys.stderr,
            )
            sys.exit(1)
        data_json = m.group(1)

    if not alerts_json:
        m2 = re.search(
            r"(?:var|const)\s+ALERTS\s*=\s*(\{.*?\}|\[.*?\]);", html, re.DOTALL
        )
        if not m2:
            print(
                "ERROR: Could not find alerts (no alerts.json, no inline ALERTS)",
                file=sys.stderr,
            )
            sys.exit(1)
        alerts_json = m2.group(1)

    # Write output
    (output_dir / "data.json").write_text(data_json)
    (output_dir / "alerts.json").write_text(alerts_json)

    # Summary
    data = json.loads(data_json)
    pts = len(data.get("results", [{}])[0].get("series", [{}])[0].get("values", []))
    alerts_parsed = json.loads(alerts_json)
    if isinstance(alerts_parsed, dict):
        alert_count = len(alerts_parsed.get("alerts", []))
    else:
        alert_count = len(alerts_parsed)
    print(f"  → {pts} data points, {alert_count} alerts extracted")


if __name__ == "__main__":
    main()
