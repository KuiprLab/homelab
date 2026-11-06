#!/usr/bin/env python3
"""Render one host's CVE report issue comment from a flakevuln per-target report.

Usage: flakevuln-comment.py REPORT_MD HOST RUN_URL

Counts unique (vulnerability, package) pairs per section, which is how flakevuln
counts "Active" in its own index. Lists new findings, findings a nixpkgs bump
would fix, and active high/critical findings, trimmed to fit a GitHub comment.
"""

import re
import sys
from datetime import datetime, timezone

COMMENT_LIMIT = 65536
BUDGET = 60000  # headroom below GitHub's comment limit
HIGH = 7.0

SECTIONS = {
    "fixed_by_bump": "Vulnerabilities Fixed by Updating Pinned nixpkgs",
    "new": "New Vulnerabilities Since Last Run",
    "gone": "Vulnerabilities No Longer Active Since Last Run",
    "active": "Currently Active Vulnerabilities",
}


def section(report, title):
    """Return (rows, available) for a section; rows are dicts keyed by header."""
    m = re.search(
        rf"<summary>{re.escape(title)}</summary>(.*?)</details>", report, re.S
    )
    if not m:
        return [], False
    lines = [ln for ln in m.group(1).splitlines() if ln.startswith("|")]
    if len(lines) < 2:
        # Only flakevuln's exact empty marker means "zero". Anything else (no
        # baseline, skipped comparison, evaluation error) means unknown.
        return [], "```No vulnerabilities```" in m.group(1)
    header = cells(lines[0])
    rows = [dict(zip(header, cells(ln))) for ln in lines[2:]]
    return rows, True


def cells(line):
    """Split a markdown table row on unescaped pipes; flakevuln escapes `|` in cells."""
    return [c.strip() for c in re.split(r"(?<!\\)\|", line.strip().strip("|"))]


def score(row):
    """Numeric severity of a row, 0.0 when it isn't a number."""
    try:
        return float(row.get("severity", ""))
    except ValueError:
        return 0.0


def merge(rows):
    """One entry per (vulnerability, package), versions joined, highest severity first."""
    merged = {}
    for r in rows:
        key = (r.get("vuln_id", ""), r.get("package", ""))
        entry = merged.setdefault(key, {**r, "versions": []})
        v = r.get("version_local", "")
        if v and v not in entry["versions"]:
            entry["versions"].append(v)
        if score(r) > score(entry):
            entry["severity"] = r.get("severity", "")
    return sorted(merged.values(), key=score, reverse=True)


def table(entries, budget):
    """Markdown table that stops before `budget` characters, noting what's left out."""
    if not entries:
        return "_None._"
    out = ["| Vulnerability | Package | Severity | Version | Input |", "|---|---|---:|---|---|"]
    used = sum(len(x) + 1 for x in out)
    for i, e in enumerate(entries):
        line = "| {} | {} | {} | {} | {} |".format(
            e.get("vuln_id", ""), e.get("package", ""), e.get("severity", ""),
            ", ".join(e["versions"]), e.get("input", ""),
        )
        if used + len(line) + 1 > budget:
            out.append(f"\n_…and {len(entries) - i} more, see the full report in the run._")
            break
        out.append(line)
        used += len(line) + 1
    return "\n".join(out)


def main():
    """Print the comment for one host's report to stdout."""
    report_path, host, run_url = sys.argv[1:4]
    report = open(report_path, encoding="utf-8").read()
    data = {k: section(report, t) for k, t in SECTIONS.items()}
    merged = {k: merge(rows) for k, (rows, _) in data.items()}

    def count(k):
        """Unique findings in section `k`, or "-" when flakevuln couldn't tell."""
        return str(len(merged[k])) if data[k][1] else "-"

    high = [e for e in merged["active"] if score(e) >= HIGH]
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    head = "\n".join([
        f"<!-- flakevuln:{host} -->",
        f"### {host}",
        f"_Updated {now} from [this run]({run_url}). Full report: run artifacts._",
        "",
        "| New | No longer active | Active | High/critical | Fixed by nixpkgs bump |",
        "|---:|---:|---:|---:|---:|",
        f"| {count('new')} | {count('gone')} | {count('active')} | {len(high)} | {count('fixed_by_bump')} |",
        "",
    ])
    parts = [head]
    left = BUDGET - len(head)
    for title, entries, opened in [
        ("New since last run", merged["new"] if data["new"][1] else None, True),
        ("Fixed by updating pinned nixpkgs", merged["fixed_by_bump"] if data["fixed_by_bump"][1] else None, True),
        ("Active high/critical", high, False),
    ]:
        if entries is None:
            continue
        block_head = f"<details{' open' if opened else ''}>\n<summary>{title} ({len(entries)})</summary>\n\n"
        block_tail = "\n\n</details>\n"
        body = table(entries, left - len(block_head) - len(block_tail))
        block = block_head + body + block_tail
        parts.append(block)
        left -= len(block)
    text = "\n".join(parts)
    assert len(text) < COMMENT_LIMIT, len(text)
    print(text)


if __name__ == "__main__":
    main()
