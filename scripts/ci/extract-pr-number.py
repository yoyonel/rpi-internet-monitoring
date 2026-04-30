#!/usr/bin/env python3
"""Extract the first PR number from a JSON array on stdin.

Prints the number, or empty string if none found.
"""

import json
import sys

prs = json.load(sys.stdin)
print(prs[0]["number"] if prs else "")
