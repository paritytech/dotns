#!/usr/bin/env python3
"""Parse forge test output and generate an HTML report.

Usage:
    python3 scripts/test-report.py test.log
"""

import os
import re
import sys
from collections import OrderedDict
from datetime import datetime, timezone
from pathlib import Path


def parse_test_log(log_path):
    """Parse forge test output into structured test results.

    Returns an ordered dict of test suites:
    { "file:Contract": { "file": str, "contract": str, "tests": [...], "suite_result": str } }
    """
    with open(log_path, encoding="utf-8", errors="ignore") as file:
        content = file.read()

    header_pattern = re.compile(
        r"(?:^|\s)(?:Running|Ran)\s+\d+\s+tests?\s+for\s+(test/[^\s:]+):([A-Za-z0-9_]+)\s*$"
    )
    suite_result_pattern = re.compile(r"^\s*Suite result:\s*(.+)\s*$")
    test_line_pattern = re.compile(
        r"^\s*\[(PASS|FAIL[^\]]*)\]\s+([A-Za-z0-9_]+)\([^)]*\)(?:\s*\(([^)]*)\))?.*$"
    )

    suites = OrderedDict()
    current_suite = None

    for line in content.splitlines():
        header_match = header_pattern.search(line)
        if header_match:
            file_path = header_match.group(1)
            contract = header_match.group(2)
            current_suite = f"{file_path}:{contract}"
            if current_suite not in suites:
                suites[current_suite] = {
                    "file": file_path,
                    "contract": contract,
                    "tests": [],
                    "suite_result": None,
                }
            continue

        test_match = test_line_pattern.match(line)
        if test_match and current_suite:
            tag = test_match.group(1)
            test_name = test_match.group(2)
            gas_info = test_match.group(3) or ""
            outcome = "PASS" if tag == "PASS" else "FAIL"

            error_message = ""
            if outcome == "FAIL":
                error_text = tag[4:].lstrip(": .").strip() if len(tag) > 4 else ""
                error_message = error_text

            suites[current_suite]["tests"].append({
                "name": test_name,
                "outcome": outcome,
                "error": error_message,
                "gas": gas_info,
            })
            continue

        suite_match = suite_result_pattern.match(line)
        if suite_match and current_suite:
            suites[current_suite]["suite_result"] = suite_match.group(1).strip()

    return suites


def generate_html(suites):
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    total_passed = sum(1 for suite in suites.values() for test in suite["tests"] if test["outcome"] == "PASS")
    total_failed = sum(1 for suite in suites.values() for test in suite["tests"] if test["outcome"] == "FAIL")
    total_tests = total_passed + total_failed

    lines = []
    lines.append('<!DOCTYPE html><html lang="en" class="dark"><head><meta charset="utf-8">')
    lines.append('<meta name="viewport" content="width=device-width,initial-scale=1">')
    lines.append("<title>DotNS Test Report</title>")
    lines.append('<script src="https://cdn.tailwindcss.com"></script>')
    lines.append("<script>tailwind.config={darkMode:'class'}</script>")
    lines.append("</head>")
    lines.append('<body class="bg-gray-950 text-gray-300 min-h-screen">')
    lines.append('<div class="max-w-6xl mx-auto px-4 py-8">')

    lines.append('<div class="mb-8">')
    lines.append('<h1 class="text-2xl font-bold text-white mb-1">DotNS Test Report</h1>')
    lines.append(f'<p class="text-sm text-gray-500">Generated {timestamp} | {len(suites)} suites</p>')
    lines.append("</div>")

    pass_color = "text-green-400" if total_failed == 0 else "text-green-400"
    fail_color = "text-red-400" if total_failed > 0 else "text-gray-500"
    status_color = "text-green-400" if total_failed == 0 else "text-red-400"
    status_text = "All Passed" if total_failed == 0 else "Failed"

    lines.append('<div class="bg-gray-900 border border-gray-800 rounded-lg p-5 mb-8"><div class="grid grid-cols-4 gap-6 text-center">')
    lines.append(f'<div><p class="text-sm text-gray-500 mb-1">Status</p><p class="text-xl font-bold {status_color}">{status_text}</p></div>')
    lines.append(f'<div><p class="text-sm text-gray-500 mb-1">Total</p><p class="text-xl font-mono text-white">{total_tests}</p></div>')
    lines.append(f'<div><p class="text-sm text-gray-500 mb-1">Passed</p><p class="text-xl font-mono {pass_color}">{total_passed}</p></div>')
    lines.append(f'<div><p class="text-sm text-gray-500 mb-1">Failed</p><p class="text-xl font-mono {fail_color}">{total_failed}</p></div>')
    lines.append("</div></div>")

    for suite_key, suite in suites.items():
        suite_passed = sum(1 for test in suite["tests"] if test["outcome"] == "PASS")
        suite_failed = sum(1 for test in suite["tests"] if test["outcome"] == "FAIL")
        suite_total = suite_passed + suite_failed
        suite_status_color = "text-green-400" if suite_failed == 0 else "text-red-400"

        lines.append('<div class="mb-4 bg-gray-900 border border-gray-800 rounded-lg">')
        lines.append('<div class="px-4 py-3 border-b border-gray-800 flex items-center justify-between">')
        lines.append(f'<div><span class="font-semibold text-white">{suite["contract"]}</span><span class="ml-2 text-xs text-gray-500">{suite["file"]}</span></div>')
        lines.append(f'<span class="text-sm font-mono {suite_status_color}">{suite_passed}/{suite_total}</span>')
        lines.append("</div>")

        if suite["tests"]:
            lines.append('<div class="overflow-x-auto"><table class="w-full text-sm">')
            lines.append('<thead><tr class="border-b border-gray-800">')
            lines.append('<th class="py-2 px-3 text-left font-semibold text-gray-400">Test</th>')
            lines.append('<th class="py-2 px-3 text-left font-semibold text-gray-400">Result</th>')
            lines.append('<th class="py-2 px-3 text-left font-semibold text-gray-400">Error</th>')
            lines.append("</tr></thead><tbody>")

            for test in suite["tests"]:
                result_color = "text-green-400" if test["outcome"] == "PASS" else "text-red-400"
                error_text = test["error"] if test["error"] else ""

                lines.append('<tr class="border-b border-gray-800/50 hover:bg-gray-800/30">')
                lines.append(f'<td class="py-2 px-3 font-mono text-gray-200">{test["name"]}</td>')
                lines.append(f'<td class="py-2 px-3 font-mono {result_color}">{test["outcome"]}</td>')
                lines.append(f'<td class="py-2 px-3 text-sm text-red-300">{error_text}</td>')
                lines.append("</tr>")

            lines.append("</tbody></table></div>")

        lines.append("</div>")

    lines.append("</div></body></html>")
    return "\n".join(lines)


def generate_markdown(suites):
    markdown_lines = []
    for suite_key, suite in suites.items():
        markdown_lines.append(f"### {suite['contract']} ({suite['file']})\n")
        markdown_lines.append("| Test | Result | Error |")
        markdown_lines.append("|:-----|:------:|:------|")
        for test in suite["tests"]:
            error = (test["error"] or "").replace("|", "\\|")
            markdown_lines.append(f"| {test['name']} | {test['outcome']} | {error} |")
        markdown_lines.append("")
    return "\n".join(markdown_lines)


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 scripts/test-report.py <test.log>")
        sys.exit(1)

    suites = parse_test_log(sys.argv[1])

    total_passed = sum(1 for suite in suites.values() for test in suite["tests"] if test["outcome"] == "PASS")
    total_failed = sum(1 for suite in suites.values() for test in suite["tests"] if test["outcome"] == "FAIL")
    total_tests = total_passed + total_failed

    github_output = os.environ.get("GITHUB_OUTPUT")
    def set_output(key, value):
        if github_output:
            with open(github_output, "a") as file:
                file.write(f"{key}={value}\n")

    if total_failed > 0:
        set_output("result", f"Failed - {total_failed} of {total_tests} tests failed")
    elif total_tests > 0:
        set_output("result", f"All tests passed ({total_tests} total)")
    else:
        set_output("result", "No tests found")

    set_output("has_details", "true" if total_tests > 0 else "false")

    if total_tests > 0:
        Path("test-report.html").write_text(generate_html(suites))
        Path("test-details.md").write_text(generate_markdown(suites))

    print(f"{total_passed} passed, {total_failed} failed out of {total_tests} tests")


if __name__ == "__main__":
    main()
