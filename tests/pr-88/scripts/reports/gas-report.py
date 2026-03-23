#!/usr/bin/env python3
"""Generate an HTML gas report comparing contract function gas usage between the current branch and main.

Uses `forge test --gas-report` to measure gas per contract function call (not per test).
Outputs gas-report.html in the repo root.

Usage:
    python3 scripts/gas-report.py
"""

import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Only include actual protocol contracts in the report.
# Test helpers, OpenZeppelin internals, and handler contracts are excluded.
PROTOCOL_CONTRACTS = {
    "StoreFactory",
    "Store",
    "DotnsRegistrar",
    "DotnsReverseResolver",
    "DotnsRegistry",
    "DotnsContentResolver",
    "DotnsResolver",
    "PopRules",
    "DotnsRegistrarController",
    "DotnsProtocolRegistry",
}


def run_shell(command, working_directory=None):
    """Run a shell command and return (stdout, stderr, return_code)."""
    result = subprocess.run(
        command,
        shell=True,
        capture_output=True,
        text=True,
        cwd=working_directory or REPO_ROOT,
    )
    return result.stdout, result.stderr, result.returncode


def parse_gas_report(raw_output):
    """Parse the output of `forge test --gas-report` into structured data.

    Returns a dict keyed by contract name:
    {
        "ContractName": {
            "deployment_cost": int,
            "deployment_size": int,
            "functions": {
                "functionName": {
                    "min": int,
                    "avg": int,
                    "median": int,
                    "max": int,
                    "calls": int,
                }
            }
        }
    }
    """
    contracts = {}
    current_contract = None
    parsing_functions = False

    # Matches lines like: | contracts/store/StoreFactory.sol:StoreFactory Contract |
    contract_header_pattern = re.compile(r"^\|?\s*contracts/[^:]+:(\w+)\s+Contract")

    # Matches deployment cost lines: | 1052780 | 4654 | | | | |
    deployment_pattern = re.compile(r"^\|\s*(\d+)\s*\|\s*(\d+)\s*\|")

    # Matches function gas lines: | deploy | 23434 | 703495 | 757547 | 774647 | 12 |
    function_pattern = re.compile(
        r"^\|\s*(\w+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|"
    )

    for line in raw_output.splitlines():
        stripped = line.strip()

        # Table boundary markers end the current contract section
        if stripped.startswith("╰") or stripped.startswith("Ran ") or stripped == "":
            if parsing_functions:
                current_contract = None
                parsing_functions = False
            continue

        # Check for a new contract section
        contract_match = contract_header_pattern.match(line)
        if contract_match:
            contract_name = contract_match.group(1)
            if contract_name in PROTOCOL_CONTRACTS:
                current_contract = contract_name
                contracts[contract_name] = {
                    "deployment_cost": 0,
                    "deployment_size": 0,
                    "functions": {},
                }
                parsing_functions = False
            else:
                current_contract = None
            continue

        if current_contract is None:
            continue

        # Check for deployment cost (appears before the function table)
        deployment_match = deployment_pattern.match(line)
        if deployment_match and not parsing_functions:
            contracts[current_contract]["deployment_cost"] = int(deployment_match.group(1))
            contracts[current_contract]["deployment_size"] = int(deployment_match.group(2))
            continue

        # The "Function Name" header row signals the start of function data
        if "Function Name" in line:
            parsing_functions = True
            continue

        # Parse individual function gas rows
        function_match = function_pattern.match(line)
        if function_match and parsing_functions:
            function_name = function_match.group(1)
            contracts[current_contract]["functions"][function_name] = {
                "min": int(function_match.group(2)),
                "avg": int(function_match.group(3)),
                "median": int(function_match.group(4)),
                "max": int(function_match.group(5)),
                "calls": int(function_match.group(6)),
            }

    return contracts


def generate_html(main_contracts, current_contracts):
    """Generate the HTML gas report comparing main vs current branch."""
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    all_contract_names = sorted(set(list(main_contracts.keys()) + list(current_contracts.keys())))

    empty_contract = {"deployment_cost": 0, "deployment_size": 0, "functions": {}}
    empty_function = {"min": 0, "avg": 0, "median": 0, "max": 0, "calls": 0}

    lines = []

    # HTML head with Tailwind
    lines.append('<!DOCTYPE html><html lang="en" class="dark"><head><meta charset="utf-8">')
    lines.append('<meta name="viewport" content="width=device-width,initial-scale=1">')
    lines.append("<title>DotNS Gas Report</title>")
    lines.append('<script src="https://cdn.tailwindcss.com"></script>')
    lines.append("<script>tailwind.config={darkMode:'class'}</script>")
    lines.append("</head>")
    lines.append('<body class="bg-gray-950 text-gray-300 min-h-screen">')
    lines.append('<div class="max-w-6xl mx-auto px-4 py-8">')

    # Page header
    lines.append('<div class="mb-8">')
    lines.append('<h1 class="text-2xl font-bold text-white mb-1">DotNS Gas Report</h1>')
    lines.append(f'<p class="text-sm text-gray-500">Generated {timestamp} | {len(all_contract_names)} contracts</p>')
    lines.append("</div>")

    # One card per contract
    for contract_name in all_contract_names:
        main_contract = main_contracts.get(contract_name, empty_contract)
        current_contract = current_contracts.get(contract_name, empty_contract)

        main_deploy_cost = main_contract["deployment_cost"]
        current_deploy_cost = current_contract["deployment_cost"]
        deploy_diff = current_deploy_cost - main_deploy_cost
        deploy_sign = "+" if deploy_diff > 0 else ""
        deploy_color = color_class(deploy_diff)

        all_function_names = sorted(
            set(list(main_contract["functions"].keys()) + list(current_contract["functions"].keys()))
        )

        # Contract card wrapper
        lines.append('<div class="mb-6 bg-gray-900 border border-gray-800 rounded-lg">')

        # Contract header with deployment cost
        lines.append('<div class="px-4 py-3 border-b border-gray-800 flex items-center justify-between">')
        lines.append(f'<span class="font-semibold text-white">{contract_name}</span>')
        lines.append(f'<span class="text-xs text-gray-500">Deploy: {current_deploy_cost:,} <span class="{deploy_color}">({deploy_sign}{deploy_diff:,})</span></span>')
        lines.append("</div>")

        if all_function_names:
            # Function gas table
            lines.append('<div class="overflow-x-auto"><table class="w-full text-sm">')
            lines.append('<thead><tr class="border-b border-gray-800">')
            lines.append('<th class="py-2 px-3 text-left font-semibold text-gray-400">Function</th>')
            lines.append('<th class="py-2 px-3 text-right font-semibold text-gray-400">Main (avg)</th>')
            lines.append('<th class="py-2 px-3 text-right font-semibold text-gray-400">Current (avg)</th>')
            lines.append('<th class="py-2 px-3 text-right font-semibold text-gray-400">Diff</th>')
            lines.append('<th class="py-2 px-3 text-right font-semibold text-gray-400">Min</th>')
            lines.append('<th class="py-2 px-3 text-right font-semibold text-gray-400">Max</th>')
            lines.append('<th class="py-2 px-3 text-right font-semibold text-gray-400">Calls</th>')
            lines.append("</tr></thead><tbody>")

            for function_name in all_function_names:
                main_function = main_contract["functions"].get(function_name, empty_function)
                current_function = current_contract["functions"].get(function_name, empty_function)

                main_avg = main_function["avg"]
                current_avg = current_function["avg"]
                avg_diff = current_avg - main_avg
                diff_sign = "+" if avg_diff > 0 else ""
                diff_color = color_class(avg_diff)

                lines.append('<tr class="border-b border-gray-800/50 hover:bg-gray-800/30">')
                lines.append(f'<td class="py-2 px-3 font-mono text-gray-200">{function_name}</td>')
                lines.append(f'<td class="py-2 px-3 font-mono text-right">{main_avg:,}</td>')
                lines.append(f'<td class="py-2 px-3 font-mono text-right">{current_avg:,}</td>')
                lines.append(f'<td class="py-2 px-3 font-mono text-right {diff_color}">{diff_sign}{avg_diff:,}</td>')
                lines.append(f'<td class="py-2 px-3 font-mono text-right text-gray-500">{current_function["min"]:,}</td>')
                lines.append(f'<td class="py-2 px-3 font-mono text-right text-gray-500">{current_function["max"]:,}</td>')
                lines.append(f'<td class="py-2 px-3 font-mono text-right text-gray-500">{current_function["calls"]:,}</td>')
                lines.append("</tr>")

            lines.append("</tbody></table></div>")
        else:
            lines.append('<p class="px-4 py-3 text-gray-500 text-sm">No function calls recorded</p>')

        lines.append("</div>")

    lines.append("</div></body></html>")
    return "\n".join(lines)


def color_class(diff_value):
    """Return a Tailwind text color class based on whether gas increased, decreased, or stayed the same."""
    if diff_value > 0:
        return "text-red-400"
    elif diff_value < 0:
        return "text-green-400"
    return "text-gray-500"


def generate_markdown_summary(main_contracts, current_contracts):
    """Generate a markdown summary of gas changes for PR comments."""
    all_contract_names = sorted(set(list(main_contracts.keys()) + list(current_contracts.keys())))
    empty_contract = {"deployment_cost": 0, "deployment_size": 0, "functions": {}}
    empty_function = {"min": 0, "avg": 0, "median": 0, "max": 0, "calls": 0}

    markdown_lines = []
    has_changes = False

    for contract_name in all_contract_names:
        main_contract = main_contracts.get(contract_name, empty_contract)
        current_contract = current_contracts.get(contract_name, empty_contract)
        all_functions = sorted(
            set(list(main_contract["functions"].keys()) + list(current_contract["functions"].keys()))
        )

        changed_functions = []
        for function_name in all_functions:
            main_avg = main_contract["functions"].get(function_name, empty_function)["avg"]
            current_avg = current_contract["functions"].get(function_name, empty_function)["avg"]
            if main_avg != current_avg:
                changed_functions.append((function_name, main_avg, current_avg, current_avg - main_avg))

        if changed_functions:
            has_changes = True
            markdown_lines.append(f"**{contract_name}**\n")
            markdown_lines.append("| Function | Main | Current | Diff |")
            markdown_lines.append("|:---------|-----:|--------:|-----:|")
            for function_name, main_avg, current_avg, diff in sorted(changed_functions, key=lambda x: abs(x[3]), reverse=True):
                sign = "+" if diff > 0 else ""
                markdown_lines.append(f"| `{function_name}` | {main_avg:,} | {current_avg:,} | {sign}{diff:,} |")
            markdown_lines.append("")

    if not has_changes:
        markdown_lines.append("No gas changes detected.")

    return "\n".join(markdown_lines), has_changes


def run_ci_mode(main_report_path, current_report_path):
    """CI mode: read pre-generated gas report files and produce HTML + markdown outputs.

    Used by the GitHub Actions workflow to avoid duplicating parsing/rendering logic.
    """
    with open(main_report_path) as file:
        main_raw = file.read()
    with open(current_report_path) as file:
        current_raw = file.read()

    main_contracts = parse_gas_report(main_raw)
    current_contracts = parse_gas_report(current_raw)

    print(f"Parsed {len(main_contracts)} contracts from main, {len(current_contracts)} from PR")

    html_content = generate_html(main_contracts, current_contracts)
    Path("gas-report.html").write_text(html_content)

    markdown_content, has_changes = generate_markdown_summary(main_contracts, current_contracts)
    Path("gas-report.md").write_text(markdown_content)

    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a") as file:
            file.write(f"has_changes={'true' if has_changes else 'false'}\n")
            file.write(f"result={len(current_contracts)} contracts analyzed\n")

    print(f"Generated gas-report.html and gas-report.md")


def run_local_mode():
    """Local mode: build both branches, generate gas reports, and produce HTML."""
    print("Building current branch and generating gas report...")
    run_shell("forge clean && forge build --force")

    current_stdout, current_stderr, _ = run_shell(
        "forge test --gas-report --no-match-path 'test/fork/*'"
    )
    current_raw_output = current_stdout + current_stderr
    current_contracts = parse_gas_report(current_raw_output)
    print(f"  Parsed {len(current_contracts)} contracts from current branch")

    print("Checking out main branch and generating gas report...")
    branch_stdout, _, _ = run_shell("git rev-parse --abbrev-ref HEAD")
    current_branch_name = branch_stdout.strip()

    stash_stdout, _, _ = run_shell("git stash --include-untracked")
    has_stashed_changes = "No local changes" not in stash_stdout

    run_shell("git checkout main")
    run_shell("forge clean && forge build --force")

    main_stdout, main_stderr, _ = run_shell(
        "forge test --gas-report --no-match-path 'test/fork/*'"
    )
    main_raw_output = main_stdout + main_stderr
    main_contracts = parse_gas_report(main_raw_output)
    print(f"  Parsed {len(main_contracts)} contracts from main branch")

    run_shell(f"git checkout {current_branch_name}")
    if has_stashed_changes:
        run_shell("git stash pop")
    run_shell("forge clean && forge build --force")

    print("Generating HTML report...")
    html_content = generate_html(main_contracts, current_contracts)

    output_path = REPO_ROOT / "gas-report.html"
    output_path.write_text(html_content)

    (REPO_ROOT / "gas-report-current.txt").write_text(current_raw_output)
    (REPO_ROOT / "gas-report-main.txt").write_text(main_raw_output)

    print(f"Report: {output_path}")
    print(f"Open:   file://{output_path}")


if __name__ == "__main__":
    if len(sys.argv) == 3:
        # CI mode: python3 scripts/gas-report.py main-gas-report.txt pr-gas-report.txt
        run_ci_mode(sys.argv[1], sys.argv[2])
    else:
        # Local mode: builds both branches automatically
        run_local_mode()
