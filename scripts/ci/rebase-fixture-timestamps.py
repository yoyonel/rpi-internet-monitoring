#!/usr/bin/env python3
"""Rebase fixture timestamps so the latest point is 5 minutes ago.

Usage: rebase-fixture-timestamps.py <fixture.json>
"""

import json
import sys
import time
from datetime import datetime, timezone


def parse_ts(s: str) -> float:
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def main() -> None:
    path = sys.argv[1]
    with open(path) as f:
        d = json.load(f)

    series = d["results"][0]["series"][0]
    vals = series["values"]

    latest = max(parse_ts(r[0]) for r in vals)
    offset = time.time() - 300 - latest  # last point = 5 min ago

    for r in vals:
        old_ts = parse_ts(r[0])
        new_dt = datetime.fromtimestamp(old_ts + offset, tz=timezone.utc)
        r[0] = new_dt.strftime("%Y-%m-%dT%H:%M:%SZ")

    with open(path, "w") as f:
        json.dump(d, f)

    print(f"Rebased {len(vals)} points, offset={offset:.0f}s")


if __name__ == "__main__":
    main()
