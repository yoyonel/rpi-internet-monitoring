#!/usr/bin/env python3
"""Read a Lighthouse category score from a report JSON file.

Usage: lighthouse-read-score.py <report.json> <category>
Prints the integer score (0-100).
"""

import json
import sys

json_file = sys.argv[1]
category = sys.argv[2]

with open(json_file) as f:
    d = json.load(f)
print(int(d["categories"][category]["score"] * 100))
