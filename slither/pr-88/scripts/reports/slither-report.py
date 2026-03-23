#!/usr/bin/env python3
"""Parse slither.json and generate an HTML report.

Usage:
    python3 scripts/slither-report.py slither.json
"""

import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

SEVERITY_ORDER = ["High", "Medium", "Low", "Informational"]
SEVERITY_COLORS = {"High": "text-red-400", "Medium": "text-yellow-400", "Low": "text-blue-400", "Informational": "text-gray-400"}


def parse_slither_json(json_path):
    if not os.path.exists(json_path):
        return {}

    with open(json_path) as file:
        data = json.load(file)

    findings = defaultdict(list)
    for detector in data.get("results", {}).get("detectors", []):
        severity = detector.get("impact", "Info").capitalize()
        location = ""
        for element in detector.get("elements", [])[:1]:
            source_mapping = element.get("source_mapping", {})
            if source_mapping.get("filename_short") and source_mapping.get("lines"):
                location = f"{source_mapping['filename_short']}:{source_mapping['lines'][0]}"

        findings[severity].append({
            "check": detector.get("check", "?"),
            "description": detector.get("description", "")[:120].replace("|", "-").replace("\n", " "),
            "location": location,
        })

    return dict(findings)


def generate_html(findings):
    total = sum(len(items) for items in findings.values())
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    lines = []
    lines.append('<!DOCTYPE html><html lang="en" class="dark"><head><meta charset="utf-8">')
    lines.append('<meta name="viewport" content="width=device-width,initial-scale=1">')
    lines.append("<title>DotNS Slither Report</title>")
    lines.append('<script src="https://cdn.tailwindcss.com"></script>')
    lines.append("<script>tailwind.config={darkMode:'class'}</script>")
    lines.append("</head>")
    lines.append('<body class="bg-gray-950 text-gray-300 min-h-screen">')
    lines.append('<div class="max-w-6xl mx-auto px-4 py-8">')

    lines.append('<div class="mb-8">')
    lines.append('<h1 class="text-2xl font-bold text-white mb-1">DotNS Slither Report</h1>')
    lines.append(f'<p class="text-sm text-gray-500">Generated {timestamp} | {total} findings</p>')
    lines.append("</div>")

    summary_parts = []
    for severity in SEVERITY_ORDER:
        count = len(findings.get(severity, []))
        if count > 0:
            color = SEVERITY_COLORS.get(severity, "text-gray-400")
            summary_parts.append(f'<div><p class="text-sm text-gray-500 mb-1">{severity}</p><p class="text-xl font-mono font-bold {color}">{count}</p></div>')

    if summary_parts:
        cols = len(summary_parts)
        lines.append(f'<div class="bg-gray-900 border border-gray-800 rounded-lg p-5 mb-8"><div class="grid grid-cols-{cols} gap-6 text-center">')
        lines.extend(summary_parts)
        lines.append("</div></div>")

    for severity in SEVERITY_ORDER:
        items = findings.get(severity, [])
        if not items:
            continue

        color = SEVERITY_COLORS.get(severity, "text-gray-400")
        lines.append(f'<h2 class="text-lg font-semibold text-white mt-8 mb-3 border-b border-gray-800 pb-2">{severity} ({len(items)})</h2>')
        lines.append('<div class="overflow-x-auto"><table class="w-full text-sm">')
        lines.append('<thead><tr class="border-b border-gray-800">')
        lines.append('<th class="py-2 px-3 text-left font-semibold text-gray-400">Check</th>')
        lines.append('<th class="py-2 px-3 text-left font-semibold text-gray-400">Description</th>')
        lines.append('<th class="py-2 px-3 text-left font-semibold text-gray-400">Location</th>')
        lines.append("</tr></thead><tbody>")

        for finding in items:
            lines.append('<tr class="border-b border-gray-800/50 hover:bg-gray-800/30">')
            lines.append(f'<td class="py-2 px-3 font-mono {color}">{finding["check"]}</td>')
            lines.append(f'<td class="py-2 px-3 text-gray-200">{finding["description"]}</td>')
            lines.append(f'<td class="py-2 px-3 font-mono text-gray-500">{finding["location"]}</td>')
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
        markdown_lines.append(f"\n**{severity} ({len(items)})**\n")
        markdown_lines.append("| Check | Description | Location |")
        markdown_lines.append("|:------|:------------|:---------|")
        for finding in items[:10]:
            markdown_lines.append(f"| {finding['check']} | {finding['description'][:80]} | {finding['location']} |")
        if len(items) > 10:
            markdown_lines.append(f"| | +{len(items) - 10} more | |")
    return "\n".join(markdown_lines)


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 scripts/slither-report.py <slither.json>")
        sys.exit(1)

    findings = parse_slither_json(sys.argv[1])
    total = sum(len(items) for items in findings.values())

    github_output = os.environ.get("GITHUB_OUTPUT")
    def set_output(key, value):
        if github_output:
            with open(github_output, "a") as file:
                file.write(f"{key}={value}\n")

    if not findings:
        set_output("result", "Passed - No issues found")
        set_output("has_details", "false")
        return

    parts = []
    for severity in SEVERITY_ORDER:
        count = len(findings.get(severity, []))
        if count > 0:
            parts.append(f"{count} {severity.lower()}")

    set_output("result", f"Found {total} issues: {', '.join(parts)}")
    set_output("has_details", "true")

    Path("slither-report.html").write_text(generate_html(findings))
    Path("slither-details.md").write_text(generate_markdown(findings))
    print(f"Found {total} issues")


if __name__ == "__main__":
    main()
