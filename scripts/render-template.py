#!/usr/bin/env python3
"""Render the monitoring page template by injecting timestamps.

Data and alerts are written as separate JSON files next to index.html
so the browser can load the lightweight HTML shell first, then fetch
the (potentially large) data payload asynchronously.

Usage:
  python3 scripts/render-template.py <template> <data> <alerts> <output> [suffix]

Arguments:
  template     Path to gh-pages/index.template.html
  data_json    Path to data.json (from extract-live-data.py)
  alerts_json  Path to alerts.json (from extract-live-data.py)
  output_html  Path to write the rendered index.html
  suffix       Optional suffix appended to __GENERATED_AT__ (e.g. "(PR preview)")
"""

import shutil
import sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

TZ = ZoneInfo("Europe/Paris")


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

    dt = datetime.now(tz=TZ)
    tz_abbr = dt.strftime("%Z")  # CET or CEST
    now = dt.strftime(f"%d/%m/%Y %H:%M ({tz_abbr})")
    now_iso = dt.isoformat()
    gen = dt.strftime(f"%d/%m/%Y à %H:%M:%S ({tz_abbr})")
    if suffix:
        gen = f"{gen} {suffix}"

    html = html.replace("__LAST_UPDATE__", now)
    html = html.replace("__LAST_UPDATE_ISO__", now_iso)
    html = html.replace("__GENERATED_AT__", gen)

    with open(output_path, "w") as f:
        f.write(html)

    # Copy data and alerts JSON files next to the rendered HTML
    out_dir = Path(output_path).parent
    for src, name in [(data_path, "data.json"), (alerts_path, "alerts.json")]:
        dst = out_dir / name
        if Path(src).resolve() != dst.resolve():
            shutil.copy2(src, dst)

    print(f"  → {output_path} ({len(html):,} bytes)")


if __name__ == "__main__":
    main()
