#!/usr/bin/env python3
"""Parse Lighthouse JSON reports and produce a prioritized action plan.

Usage:
    python3 scripts/lighthouse-report.py [mobile|desktop|both]

Reads from lighthouse-reports/latest-{preset}.report.json (symlinks
created by scripts/lighthouse.sh).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

REPORT_DIR = Path(__file__).resolve().parent.parent / "lighthouse-reports"

# ── Colours ──────────────────────────────────────────────

RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
RED = "\033[91m"
YELLOW = "\033[93m"
GREEN = "\033[92m"
CYAN = "\033[96m"
MAGENTA = "\033[95m"
WHITE = "\033[97m"
BG_RED = "\033[41m"
BG_YELLOW = "\033[43m"
BG_GREEN = "\033[42m"

SEPARATOR = f"{DIM}{'─' * 72}{RESET}"


def score_badge(score: int) -> str:
    if score >= 90:
        return f"{BG_GREEN}{BOLD} {score:>3} {RESET}"
    if score >= 50:
        return f"{BG_YELLOW}{BOLD} {score:>3} {RESET}"
    return f"{BG_RED}{BOLD} {score:>3} {RESET}"


def score_colour(score: float) -> str:
    if score >= 0.9:
        return GREEN
    if score >= 0.5:
        return YELLOW
    return RED


def priority_label(score: float | None, savings_ms: float) -> tuple[int, str]:
    """Return (sort_key, label) — lower key = higher priority."""
    if savings_ms > 500 or (score is not None and score == 0):
        return 1, f"{RED}{BOLD}HIGH{RESET}"
    if savings_ms > 100 or (score is not None and score < 0.5):
        return 2, f"{YELLOW}{BOLD}MEDIUM{RESET}"
    return 3, f"{GREEN}LOW{RESET}"


def fmt_ms(ms: float) -> str:
    if ms >= 1000:
        return f"{ms / 1000:.1f} s"
    return f"{ms:.0f} ms"


def fmt_bytes(b: float) -> str:
    if b >= 1024 * 1024:
        return f"{b / (1024 * 1024):.1f} MB"
    if b >= 1024:
        return f"{b / 1024:.1f} KB"
    return f"{b:.0f} B"


# ── Report parsing ───────────────────────────────────────


def load_report(preset: str) -> dict:
    p = REPORT_DIR / f"latest-{preset}.report.json"
    if not p.exists():
        sys.exit(f"❌ Report not found: {p}\n   Run:  just lighthouse --{preset}")
    return json.loads(p.read_text())


def print_scores(data: dict, preset: str) -> None:
    cats = data["categories"]
    print()
    print(f"  {BOLD}{CYAN}{'═' * 50}{RESET}")
    print(f"  {BOLD}{CYAN}  LIGHTHOUSE — {preset.upper()}{RESET}")
    print(f"  {BOLD}{CYAN}{'═' * 50}{RESET}")
    print()
    for key in ("performance", "accessibility", "best-practices", "seo"):
        cat = cats[key]
        score = int(cat["score"] * 100)
        print(f"    {score_badge(score)}  {cat['title']}")
    print()


def collect_opportunities(data: dict) -> list[dict]:
    """Collect failed/partial audits with actionable savings."""
    results = []
    for _key, audit in data["audits"].items():
        score = audit.get("score")
        mode = audit.get("scoreDisplayMode", "")
        if mode in ("notApplicable", "manual"):
            continue
        if score is None or score >= 1:
            continue

        savings = audit.get("metricSavings", {})
        total_savings_ms = sum(
            v for v in savings.values() if isinstance(v, (int, float))
        )
        numeric = audit.get("numericValue", 0) or 0
        display_value = audit.get("displayValue", "")
        items = audit.get("details", {}).get("items", [])

        results.append(
            {
                "title": audit["title"],
                "score": score,
                "description": audit.get("description", "").split("[")[0].strip(),
                "display_value": display_value,
                "savings_ms": total_savings_ms,
                "numeric_value": numeric,
                "items": items,
                "category": _find_category(data, _key),
            }
        )
    return results


def _find_category(data: dict, audit_id: str) -> str:
    for cat_key, cat in data["categories"].items():
        for ref in cat.get("auditRefs", []):
            if ref["id"] == audit_id:
                return cat_key
    return "other"


CATEGORY_ICONS = {
    "performance": "⚡",
    "accessibility": "♿",
    "best-practices": "✅",
    "seo": "🔍",
    "other": "📋",
}

CATEGORY_ORDER = {
    "performance": 0,
    "accessibility": 1,
    "best-practices": 2,
    "seo": 3,
    "other": 4,
}


def print_opportunities(opps: list[dict]) -> None:
    if not opps:
        print(f"  {GREEN}{BOLD}No issues found — all audits passed!{RESET}")
        return

    # Sort: priority first, then by savings_ms descending
    decorated = []
    for idx, o in enumerate(opps):
        pri_key, pri_label = priority_label(o["score"], o["savings_ms"])
        decorated.append(
            (
                pri_key,
                -o["savings_ms"],
                CATEGORY_ORDER.get(o["category"], 9),
                idx,
                o,
                pri_label,
            )
        )
    decorated.sort()

    current_priority = None
    for pri_key, _, _, _idx, o, _pri_label in decorated:
        if pri_key != current_priority:
            current_priority = pri_key
            header = {
                1: "HIGH PRIORITY",
                2: "MEDIUM PRIORITY",
                3: "LOW PRIORITY",
            }[pri_key]
            colour = {1: RED, 2: YELLOW, 3: GREEN}[pri_key]
            print(SEPARATOR)
            print(f"  {colour}{BOLD}▸ {header}{RESET}")
            print(SEPARATOR)
            print()

        icon = CATEGORY_ICONS.get(o["category"], "📋")
        sc = score_colour(o["score"])
        score_pct = int(o["score"] * 100)

        print(f"  {icon} {BOLD}{o['title']}{RESET}  {sc}({score_pct}%){RESET}", end="")
        if o["display_value"]:
            print(f"  {DIM}— {o['display_value']}{RESET}", end="")
        print()

        if o["savings_ms"]:
            print(f"     {MAGENTA}Potential savings: {fmt_ms(o['savings_ms'])}{RESET}")

        if o["description"]:
            desc = o["description"][:120]
            print(f"     {DIM}{desc}{RESET}")

        # Show top items (URLs, elements, etc.)
        items = o["items"][:5]
        if items:
            print(f"     {DIM}┌{'─' * 60}{RESET}")
            for item in items:
                line = _format_item(item)
                if line:
                    print(f"     {DIM}│{RESET} {line}")
            if len(o["items"]) > 5:
                print(f"     {DIM}│ … and {len(o['items']) - 5} more{RESET}")
            print(f"     {DIM}└{'─' * 60}{RESET}")
        print()


def _format_item(item: dict) -> str:
    """Format a single detail item into a readable line."""
    parts = []

    # URL (truncate CDN paths)
    url = item.get("url", "")
    if url:
        short = url.replace("https://cdn.jsdelivr.net/npm/", "cdn:")
        short = short.replace(
            "https://yoyonel.github.io/rpi-internet-monitoring/",
            "./",
        )
        short = short.replace("https://fonts.googleapis.com/", "fonts:")
        parts.append(f"{CYAN}{short}{RESET}")

    # Node/element selector
    node = item.get("node", {})
    if isinstance(node, dict) and node.get("selector"):
        parts.append(f"{MAGENTA}{node['selector']}{RESET}")

    # Wasted bytes
    wasted = item.get("wastedBytes", 0)
    if wasted:
        parts.append(f"{YELLOW}-{fmt_bytes(wasted)}{RESET}")

    # Wasted ms
    wasted_ms = item.get("wastedMs", 0)
    if wasted_ms:
        parts.append(f"{YELLOW}-{fmt_ms(wasted_ms)}{RESET}")

    # Total bytes
    total = item.get("totalBytes", 0)
    if total and not wasted:
        parts.append(f"{DIM}({fmt_bytes(total)}){RESET}")

    # SubItems (e.g. contrast ratio)
    sub = item.get("subItems", {}).get("items", [])
    if sub:
        for s in sub[:2]:
            for _k, v in s.items():
                if isinstance(v, str) and v:
                    parts.append(f"{DIM}{v}{RESET}")
                    break

    return "  ".join(parts) if parts else ""


def print_quick_wins(opps: list[dict]) -> None:
    """Show a short summary of the easiest wins."""
    # Quick wins = high savings, simple fixes
    quick_cats = ("accessibility", "seo", "best-practices")
    wins = [o for o in opps if o["category"] in quick_cats and o["score"] == 0]
    if not wins:
        return

    print(SEPARATOR)
    print(f"  {CYAN}{BOLD}⚡ QUICK WINS (non-performance, easy fixes){RESET}")
    print(SEPARATOR)
    print()
    for w in wins:
        icon = CATEGORY_ICONS.get(w["category"], "📋")
        print(f"  {icon} {w['title']}")
        if w["description"]:
            print(f"     {DIM}{w['description'][:120]}{RESET}")
        print()


# ── Main ─────────────────────────────────────────────────


def analyse(preset: str) -> None:
    data = load_report(preset)
    print_scores(data, preset)
    opps = collect_opportunities(data)
    print_quick_wins(opps)
    print_opportunities(opps)


def main() -> None:
    arg = sys.argv[1] if len(sys.argv) > 1 else "both"
    presets = ["mobile", "desktop"] if arg == "both" else [arg]

    for preset in presets:
        analyse(preset)

    print(SEPARATOR)
    print(f"  {DIM}Full HTML reports:{RESET}")
    for preset in presets:
        p = REPORT_DIR / f"latest-{preset}.report.html"
        print(f"    {CYAN}{p}{RESET}")
    print()


if __name__ == "__main__":
    main()
