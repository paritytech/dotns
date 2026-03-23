#!/usr/bin/env python3
"""Parse forge coverage output and generate an HTML report + markdown summary.

Usage:
    python3 scripts/coverage-report.py coverage.log

Reads the output of `forge coverage --report summary` and produces:
  - coverage-report.html (Tailwind-styled page for GitHub Pages)
  - coverage-details.md (markdown table for PR comment)
  - GITHUB_OUTPUT variables: result, has_details
"""

import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


def parse_coverage_log(log_path):
    """Parse forge coverage summary output into structured data.

    Returns a list of dicts and a total line coverage percentage:
    [{ "name": "contracts/store/Store.sol", "lines": 85.0, "statements": 80.0, "branches": 70.0, "functions": 90.0 }], 77.5
    """
    with open(log_path) as file:
        content = file.read()

    if "vm.readFile" in content and "No such file or directory" in content:
        return [], None, "skipped"

    if "Failing tests:" in content:
        return [], None, "tests_failed"

    files = []
    total_line_coverage = None

    file_row_pattern = re.compile(
        r"\|\s*([^\|]+\.sol)\s*\|\s*([\d.]+)%\s*\(\d+/\d+\)\s*\|\s*([\d.]+)%\s*\(\d+/\d+\)\s*\|\s*([\d.]+)%\s*\(\d+/\d+\)\s*\|\s*([\d.]+)%"
    )
    total_row_pattern = re.compile(r"\|\s*Total\s*\|\s*([\d.]+)%")

    for line in content.splitlines():
        file_match = file_row_pattern.match(line)
        if file_match:
            file_name = file_match.group(1).strip()
            if not file_name.startswith("test/") and not file_name.startswith("lib/"):
                files.append({
                    "name": file_name,
                    "lines": float(file_match.group(2)),
                    "statements": float(file_match.group(3)),
                    "branches": float(file_match.group(4)),
                    "functions": float(file_match.group(5)),
                })

        total_match = total_row_pattern.match(line)
        if total_match:
            total_line_coverage = float(total_match.group(1))

    if total_line_coverage is None and files:
        total_line_coverage = sum(file_entry["lines"] for file_entry in files) / len(files)

    return files, total_line_coverage, "ok"


def coverage_color_class(percentage):
    """Return a Tailwind text color class based on coverage percentage."""
    if percentage >= 80:
        return "text-green-400"
    elif percentage >= 60:
        return "text-yellow-400"
    return "text-red-400"


def coverage_bg_class(percentage):
    """Return a Tailwind background color class for progress bars."""
    if percentage >= 80:
        return "bg-green-500"
    elif percentage >= 60:
        return "bg-yellow-500"
    return "bg-red-500"


def generate_html(files, total_line_coverage):
    """Generate a Tailwind-styled HTML coverage report."""
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    sorted_files = sorted(files, key=lambda file_entry: file_entry["lines"])

    lines = []
    lines.append('<!DOCTYPE html><html lang="en" class="dark"><head><meta charset="utf-8">')
    lines.append('<meta name="viewport" content="width=device-width,initial-scale=1">')
    lines.append("<title>DotNS Coverage Report</title>")
    lines.append('<script src="https://cdn.tailwindcss.com"></script>')
    lines.append("<script>tailwind.config={darkMode:'class'}</script>")
    lines.append("</head>")
    lines.append('<body class="bg-gray-950 text-gray-300 min-h-screen">')
    lines.append('<div class="max-w-6xl mx-auto px-4 py-8">')

    lines.append('<div class="mb-8">')
    lines.append('<h1 class="text-2xl font-bold text-white mb-1">DotNS Coverage Report</h1>')
    lines.append(f'<p class="text-sm text-gray-500">Generated {timestamp} | {len(files)} files</p>')
    lines.append("</div>")

    total_color = coverage_color_class(total_line_coverage or 0)
    total_bg = coverage_bg_class(total_line_coverage or 0)
    lines.append('<div class="bg-gray-900 border border-gray-800 rounded-lg p-5 mb-8">')
    lines.append('<div class="flex items-center justify-between mb-3">')
    lines.append(f'<span class="text-lg font-semibold text-white">Line Coverage</span>')
    lines.append(f'<span class="text-2xl font-mono font-bold {total_color}">{total_line_coverage:.1f}%</span>')
    lines.append("</div>")
    lines.append(f'<div class="w-full bg-gray-800 rounded-full h-3">')
    lines.append(f'<div class="{total_bg} h-3 rounded-full" style="width: {min(total_line_coverage or 0, 100)}%"></div>')
    lines.append("</div></div>")

    averages = {
        "statements": sum(file_entry["statements"] for file_entry in files) / len(files) if files else 0,
        "branches": sum(file_entry["branches"] for file_entry in files) / len(files) if files else 0,
        "functions": sum(file_entry["functions"] for file_entry in files) / len(files) if files else 0,
    }

    lines.append('<div class="grid grid-cols-3 gap-4 mb-8">')
    for label, value in averages.items():
        color = coverage_color_class(value)
        lines.append(f'<div class="bg-gray-900 border border-gray-800 rounded-lg p-4 text-center">')
        lines.append(f'<p class="text-sm text-gray-500 mb-1">{label.capitalize()}</p>')
        lines.append(f'<p class="text-xl font-mono font-bold {color}">{value:.1f}%</p>')
        lines.append("</div>")
    lines.append("</div>")

    lines.append('<div class="bg-gray-900 border border-gray-800 rounded-lg">')
    lines.append('<div class="px-4 py-3 border-b border-gray-800">')
    lines.append('<span class="font-semibold text-white">Per-File Breakdown</span>')
    lines.append("</div>")
    lines.append('<div class="overflow-x-auto"><table class="w-full text-sm">')
    lines.append('<thead><tr class="border-b border-gray-800">')
    lines.append('<th class="py-2 px-3 text-left font-semibold text-gray-400">File</th>')
    lines.append('<th class="py-2 px-3 text-right font-semibold text-gray-400">Lines</th>')
    lines.append('<th class="py-2 px-3 text-right font-semibold text-gray-400">Statements</th>')
    lines.append('<th class="py-2 px-3 text-right font-semibold text-gray-400">Branches</th>')
    lines.append('<th class="py-2 px-3 text-right font-semibold text-gray-400">Functions</th>')
    lines.append("</tr></thead><tbody>")

    for file_entry in sorted_files:
        file_name = file_entry["name"]
        if file_name.startswith("contracts/"):
            file_name = file_name[len("contracts/"):]

        line_color = coverage_color_class(file_entry["lines"])
        stmt_color = coverage_color_class(file_entry["statements"])
        branch_color = coverage_color_class(file_entry["branches"])
        func_color = coverage_color_class(file_entry["functions"])

        lines.append('<tr class="border-b border-gray-800/50 hover:bg-gray-800/30">')
        lines.append(f'<td class="py-2 px-3 font-mono text-gray-200">{file_name}</td>')
        lines.append(f'<td class="py-2 px-3 font-mono text-right {line_color}">{file_entry["lines"]:.1f}%</td>')
        lines.append(f'<td class="py-2 px-3 font-mono text-right {stmt_color}">{file_entry["statements"]:.1f}%</td>')
        lines.append(f'<td class="py-2 px-3 font-mono text-right {branch_color}">{file_entry["branches"]:.1f}%</td>')
        lines.append(f'<td class="py-2 px-3 font-mono text-right {func_color}">{file_entry["functions"]:.1f}%</td>')
        lines.append("</tr>")

    lines.append("</tbody></table></div></div>")
    lines.append("</div></body></html>")
    return "\n".join(lines)


def generate_markdown(files):
    """Generate a markdown table for the PR comment collapsible section."""
    if not files:
        return ""

    sorted_files = sorted(files, key=lambda file_entry: file_entry["lines"])
    markdown_lines = []
    markdown_lines.append("| File | Lines | Statements | Branches | Functions |")
    markdown_lines.append("|:-----|------:|-----------:|---------:|----------:|")

    for file_entry in sorted_files:
        name = file_entry["name"]
        if len(name) > 50:
            name = "..." + name[-47:]
        markdown_lines.append(
            f"| {name} | {file_entry['lines']:.1f}% | {file_entry['statements']:.1f}% "
            f"| {file_entry['branches']:.1f}% | {file_entry['functions']:.1f}% |"
        )

    return "\n".join(markdown_lines)


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 scripts/coverage-report.py coverage.log")
        sys.exit(1)

    log_path = sys.argv[1]
    files, total_line_coverage, status = parse_coverage_log(log_path)

    github_output = os.environ.get("GITHUB_OUTPUT")

    def set_output(key, value):
        if github_output:
            with open(github_output, "a") as file:
                file.write(f"{key}={value}\n")

    if status == "skipped":
        set_output("result", "Skipped - Tests use vm.readFile (incompatible with coverage)")
        set_output("has_details", "false")
        return

    if status == "tests_failed":
        set_output("result", "Failed - Tests failed, cannot compute coverage")
        set_output("has_details", "false")
        return

    if not files and total_line_coverage is None:
        set_output("result", "Failed - No coverage data parsed")
        set_output("has_details", "false")
        return

    set_output("result", f"{total_line_coverage:.1f}% line coverage")
    set_output("has_details", "true" if files else "false")

    if files:
        html_content = generate_html(files, total_line_coverage)
        Path("coverage-report.html").write_text(html_content)

        markdown_content = generate_markdown(files)
        Path("coverage-details.md").write_text(markdown_content)

        print(f"Coverage: {total_line_coverage:.1f}% across {len(files)} files")
        print("Generated coverage-report.html and coverage-details.md")


if __name__ == "__main__":
    main()
