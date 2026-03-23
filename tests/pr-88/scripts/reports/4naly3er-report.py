#!/usr/bin/env python3
"""Parse 4naly3er report.md and generate an HTML report.

Usage:
    python3 scripts/4naly3er-report.py .4naly3er/report.md
"""

import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

SEVERITY_ORDER = ["H", "M", "L", "GAS", "NC"]
SEVERITY_LABELS = {"H": "High", "M": "Medium", "L": "Low", "GAS": "Gas", "NC": "Informational"}
SEVERITY_COLORS = {"H": "text-red-400", "M": "text-yellow-400", "L": "text-blue-400", "GAS": "text-gray-400", "NC": "text-gray-500"}


def parse_report(report_path):
    if not os.path.exists(report_path):
        return {}

    with open(report_path, encoding="utf-8") as file:
        content = file.read()

    findings = defaultdict(list)
    pattern = r"\|\s*\[([A-Z]+)-(\d+)\]\([^)]*\)\s*\|\s*([^|]+)\|\s*(\d+)\s*\|"

    for match in re.finditer(pattern, content):
        category, number, title, instances = match.groups()
        finding_id = f"{category}-{number}"
        if not any(f["id"] == finding_id for f in findings[category]):
            findings[category].append({
                "id": finding_id,
                "title": title.strip()[:100].replace("|", "-"),
                "instances": int(instances.strip()),
            })

    return dict(findings)


def generate_html(findings):
    total = sum(len(items) for items in findings.values())
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    lines = []
    lines.append('<!DOCTYPE html><html lang="en" class="dark"><head><meta charset="utf-8">')
    lines.append('<meta name="viewport" content="width=device-width,initial-scale=1">')
    lines.append("<title>DotNS 4naly3er Report</title>")
    lines.append('<script src="https://cdn.tailwindcss.com"></script>')
    lines.append("<script>tailwind.config={darkMode:'class'}</script>")
    lines.append("</head>")
    lines.append('<body class="bg-gray-950 text-gray-300 min-h-screen">')
    lines.append('<div class="max-w-6xl mx-auto px-4 py-8">')

    lines.append('<div class="mb-8">')
    lines.append('<h1 class="text-2xl font-bold text-white mb-1">DotNS 4naly3er Report</h1>')
    lines.append(f'<p class="text-sm text-gray-500">Generated {timestamp} | {total} findings</p>')
    lines.append("</div>")

    summary_parts = []
    for severity in SEVERITY_ORDER:
        count = len(findings.get(severity, []))
        if count > 0:
            color = SEVERITY_COLORS[severity]
            summary_parts.append(f'<div><p class="text-sm text-gray-500 mb-1">{SEVERITY_LABELS[severity]}</p><p class="text-xl font-mono font-bold {color}">{count}</p></div>')

    if summary_parts:
        cols = len(summary_parts)
        lines.append(f'<div class="bg-gray-900 border border-gray-800 rounded-lg p-5 mb-8"><div class="grid grid-cols-{cols} gap-6 text-center">')
        lines.extend(summary_parts)
        lines.append("</div></div>")

    for severity in SEVERITY_ORDER:
        items = findings.get(severity, [])
        if not items:
            continue

        label = SEVERITY_LABELS[severity]
        color = SEVERITY_COLORS[severity]

        lines.append(f'<h2 class="text-lg font-semibold text-white mt-8 mb-3 border-b border-gray-800 pb-2">{label} ({len(items)})</h2>')
        lines.append('<div class="overflow-x-auto"><table class="w-full text-sm">')
        lines.append('<thead><tr class="border-b border-gray-800">')
        lines.append('<th class="py-2 px-3 text-left font-semibold text-gray-400">ID</th>')
        lines.append('<th class="py-2 px-3 text-left font-semibold text-gray-400">Finding</th>')
        lines.append('<th class="py-2 px-3 text-right font-semibold text-gray-400">Instances</th>')
        lines.append("</tr></thead><tbody>")

        for finding in items:
            lines.append('<tr class="border-b border-gray-800/50 hover:bg-gray-800/30">')
            lines.append(f'<td class="py-2 px-3 font-mono {color}">{finding["id"]}</td>')
            lines.append(f'<td class="py-2 px-3 text-gray-200">{finding["title"]}</td>')
            lines.append(f'<td class="py-2 px-3 font-mono text-right">{finding["instances"]}</td>')
            lines.append("</tr>")

        lines.append("</tbody></table></div>")

    if not findings:
        lines.append('<p class="text-gray-500 mt-4">No issues found.</p>')

    lines.append("</div></body></html>")
    return "\n".join(lines)


def generate_markdown(findings):
    markdown_lines = []
    for severity in SEVERITY_ORDER:
        items = findings.get(severity, [])
        if not items:
            continue
        label = SEVERITY_LABELS[severity]
        markdown_lines.append(f"\n**{label} ({len(items)})**\n")
        markdown_lines.append("| ID | Finding | Instances |")
        markdown_lines.append("|:---|:--------|:---------:|")
        for finding in items[:15]:
            markdown_lines.append(f"| {finding['id']} | {finding['title'][:70]} | {finding['instances']} |")
        if len(items) > 15:
            markdown_lines.append(f"| | +{len(items) - 15} more | |")
    return "\n".join(markdown_lines)


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 scripts/4naly3er-report.py <report.md>")
        sys.exit(1)

    findings = parse_report(sys.argv[1])
    total = sum(len(items) for items in findings.values())

    github_output = os.environ.get("GITHUB_OUTPUT")
    def set_output(key, value):
        if github_output:
            with open(github_output, "a") as file:
                file.write(f"{key}={value}\n")

    if not findings:
        set_output("result", "No issues found")
        set_output("has_details", "false")
        return

    parts = []
    for severity in SEVERITY_ORDER:
        count = len(findings.get(severity, []))
        if count > 0:
            parts.append(f"{count} {SEVERITY_LABELS[severity].lower()}")

    set_output("result", f"Found {total} issues: {', '.join(parts)}")
    set_output("has_details", "true")

    Path("4naly3er-report.html").write_text(generate_html(findings))
    Path("4naly3er-details.md").write_text(generate_markdown(findings))
    print(f"Found {total} issues")


if __name__ == "__main__":
    main()
