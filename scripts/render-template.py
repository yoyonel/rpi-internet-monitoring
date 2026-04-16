#!/usr/bin/env python3
"""Render the monitoring page template by injecting data and alerts.

Usage:
  python3 scripts/render-template.py <template> <data> <alerts> <output> [suffix]

Arguments:
  template     Path to gh-pages/index.template.html
  data_json    Path to data.json (from extract-live-data.py)
  alerts_json  Path to alerts.json (from extract-live-data.py)
  output_html  Path to write the rendered index.html
  suffix       Optional suffix appended to __GENERATED_AT__ (e.g. "(PR preview)")
"""

import sys
from datetime import datetime


def main():
    if len(sys.argv) < 5:
        print(
            f"Usage: {sys.argv[0]} <template> <data> <alerts> <output> [suffix]",
            file=sys.stderr,
        )
        sys.exit(1)

    template_path = sys.argv[1]
    data_path = sys.argv[2]
    alerts_path = sys.argv[3]
    output_path = sys.argv[4]
    suffix = sys.argv[5] if len(sys.argv) > 5 else ""

    with open(template_path) as f:
        html = f.read()
    with open(data_path) as f:
        data = f.read().strip()
    with open(alerts_path) as f:
        alerts = f.read().strip()

    now = datetime.now().strftime("%d/%m/%Y %H:%M")
    gen = datetime.now().strftime("%d/%m/%Y à %H:%M:%S")
    if suffix:
        gen = f"{gen} {suffix}"

    html = html.replace('"__SPEEDTEST_DATA__"', data)
    html = html.replace('"__ALERTS_DATA__"', alerts)
    html = html.replace("__LAST_UPDATE__", now)
    html = html.replace("__GENERATED_AT__", gen)

    with open(output_path, "w") as f:
        f.write(html)

    assert "__SPEEDTEST_DATA__" not in html, "Data injection failed"
    assert "__ALERTS_DATA__" not in html, "Alerts injection failed"
    print(f"  → {output_path} ({len(html):,} bytes)")


if __name__ == "__main__":
    main()
