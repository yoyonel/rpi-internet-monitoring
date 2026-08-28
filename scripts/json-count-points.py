#!/usr/bin/env python3
"""Count data points in an InfluxDB JSON response (reads stdin)."""

import json
import sys

d = json.load(sys.stdin)
s = d.get("results", [{}])[0].get("series", [{}])
print(len(s[0].get("values", [])) if s else 0)
