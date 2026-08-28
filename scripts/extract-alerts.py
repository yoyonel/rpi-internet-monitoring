#!/usr/bin/env python3
"""Extract Grafana alert rules from Prometheus rules API JSON.

Reads JSON from stdin.
Default: prints compact JSON with alerts and lastEvaluation.
With --count: prints the number of alerts from already-extracted JSON.
"""

import argparse
import json
import sys


def extract(data):
    alerts = []
    last_eval = ""
    for g in data.get("data", {}).get("groups", []):
        ge = g.get("lastEvaluation", "")
        if ge > last_eval:
            last_eval = ge
        for r in g.get("rules", []):
            val = ""
            re_val = r.get("lastEvaluation", ge)
            for a in r.get("alerts", []):
                s = a.get("annotations", {}).get("summary", "")
                if s:
                    val = s
            alerts.append(
                {
                    "name": r["name"],
                    "state": r["state"],
                    "health": r.get("health", ""),
                    "severity": r.get("labels", {}).get("severity", ""),
                    "summary": val,
                    "lastEvaluation": re_val,
                }
            )
    return {"alerts": alerts, "lastEvaluation": last_eval}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", action="store_true", help="Count alerts in stdin")
    args = parser.parse_args()

    data = json.load(sys.stdin)

    if args.count:
        if isinstance(data, dict):
            print(len(data.get("alerts", data)))
        else:
            print(len(data))
    else:
        print(json.dumps(extract(data)))


if __name__ == "__main__":
    main()
