#!/usr/bin/env bash
set -euo pipefail

# Validates a NUL-separated list of file paths read from stdin, applying the
# repository's content checks: per-file-type syntax validation, no decorative
# separator comments, no trailing inline comments, and no CRLF in the
# abi-contracts manifest. Shared by the pre-commit hook (staged files) and the
# File Validation CI workflow (every tracked file) so the two never drift. Reads
# working-tree content. Exits non-zero and prints a report if any file fails.
#
# Usage: <nul-separated paths on stdin> | validate-files.sh
#   pre-commit:  git diff --cached --name-only -z --diff-filter=ACMR | validate-files.sh
#   CI:          git ls-files -z | validate-files.sh

# Source the shared PATH augmentation via a git-independent path so the checks
# find their interpreters under a minimal-environment shell; it no-ops on any
# path that does not exist (so it is inert on a Linux CI runner).
# shellcheck source=scripts/shell/lib-hook-env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-hook-env.sh"

# Paths are validated relative to the current directory, so the caller sets it:
# CI runs from the repository root, and the pre-commit hook runs from a temp tree
# holding the staged (index) content, so the check sees exactly what is committed.

validation_errors="$(mktemp)"
validation_detail="$(mktemp)"
cleanup() {
  rm -f "$validation_errors" "$validation_detail"
}
trap cleanup EXIT

record_validation_failure() {
  local file="$1"
  local check="$2"

  {
    echo "$file: failed $check"
    sed 's/^/  /' "$validation_detail"
  } >>"$validation_errors"
}

run_validation() {
  local file="$1"
  local check="$2"
  shift 2

  : >"$validation_detail"
  if ! "$@" > /dev/null 2>"$validation_detail"; then
    record_validation_failure "$file" "$check"
  fi
}

validate_toml() {
  local file="$1"

  run_validation "$file" "TOML validation" python3 -c 'import pathlib, sys, tomllib; tomllib.loads(pathlib.Path(sys.argv[1]).read_text())' "$file"
}

validate_env_file() {
  local file="$1"

  run_validation "$file" "environment-file validation" ruby -e '
    file = ARGV.fetch(0)
    ARGF.each_line.with_index(1) do |line, number|
      next if line.match?(/\A\s*(#.*)?\s*\z/)
      next if line.match?(/\A[A-Za-z_][A-Za-z0-9_]*=.*\s*\z/)
      raise "#{file}:#{number}: expected KEY=value, blank line, or comment"
    end
  ' "$file"
}

validate_git_config_file() {
  local file="$1"

  run_validation "$file" "git-config validation" git config --file "$file" --list
}

validate_abi_contracts() {
  local file="$1"

  # Each line becomes part of an artifact path in the publish workflows, so a
  # carriage return from a CRLF save turns into out/Name\r.sol/Name\r.json and
  # aborts the release. Reject it here instead.
  run_validation "$file" "line-ending validation" awk '/\r/ { exit 1 }' "$file"
}

# Rejects decorative separator comments: a comment whose content is a run of
# rule characters, such as a line of dashes or equals under a heading. Prose
# and bullet lists are untouched because they carry words, not a bare run.
_reject_separator_comments() {
  if grep -nE '^[[:space:]]*(//+|/\*|\*|#)[[:space:]]*[-=*_~#]{6,}|^[[:space:]]*/{6,}[[:space:]]*$' "$1" >&2; then
    return 1
  fi
  return 0
}

validate_no_separator_comments() {
  local file="$1"

  run_validation "$file" "decorative-separator check" _reject_separator_comments "$file"
}

# Rejects trailing inline comments: a run of two or more slashes that follows code
# on the same line, including `///`. A comment belongs on its own line above the
# code it describes. Full-line and doc comments on their own line are fine, an
# inline tool directive such as solhint-disable-line is allowed because it only
# works on the line it annotates, and a `://` inside a URL is skipped. The check
# is a line regex, not a parser, so a `//` inside a string, template, or regex
# literal, or in a multi-line block-comment body, is a known false positive.
_reject_trailing_comments() {
  local hits
  hits="$(
    grep -nE '^[[:space:]]*[^/*[:space:]].*[^:/]/{2,}' "$1" 2>/dev/null \
      | grep -vE '//[[:space:]]*(solhint-disable(-next)?-line|eslint-disable(-next)?-line|prettier-ignore|slither-disable(-next)?-line|forge-lint:|@ts-(expect-error|ignore|nocheck))' 2>/dev/null \
      || true
  )"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" >&2
    return 1
  fi
  return 0
}

validate_no_trailing_comments() {
  local file="$1"

  run_validation "$file" "trailing-comment check" _reject_trailing_comments "$file"
}

# Read the whole NUL-separated list before validating so a per-file check cannot
# consume the loop's stdin. `${files[@]:-}` keeps `set -u` happy on an empty list.
files=()
while IFS= read -r -d '' file; do
  files+=("$file")
done

for file in "${files[@]:-}"; do
  [ -n "$file" ] || continue
  [ -f "$file" ] || continue

  case "$file" in
    lib/*|node_modules/*)
      continue
      ;;
    *.bash|*.sh|setup.bash|.githooks/*)
      run_validation "$file" "shell validation" bash -n "$file"
      ;;
    *.cjs|*.js|*.mjs)
      run_validation "$file" "JavaScript validation" node --check "$file"
      ;;
    *.json)
      run_validation "$file" "JSON validation" jq -e . "$file"
      ;;
    *.py)
      run_validation "$file" "Python validation" python3 -c 'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text(), filename=sys.argv[1])' "$file"
      ;;
    *.toml)
      validate_toml "$file"
      ;;
    *.yaml|*.yml)
      run_validation "$file" "YAML validation" ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "$file"
      ;;
    .env.example)
      validate_env_file "$file"
      ;;
    .gitmodules)
      validate_git_config_file "$file"
      ;;
    .github/abi-contracts.txt)
      validate_abi_contracts "$file"
      ;;
  esac

  case "$file" in
    lib/*|node_modules/*)
      ;;
    *.sol|*.ts|*.tsx|*.mts|*.cts|*.js|*.jsx|*.cjs|*.mjs|*.sh|*.bash|*.py)
      validate_no_separator_comments "$file"
      ;;
  esac

  case "$file" in
    lib/*|node_modules/*)
      ;;
    *.sol|*.ts|*.tsx|*.mts|*.cts|*.js|*.jsx|*.cjs|*.mjs)
      validate_no_trailing_comments "$file"
      ;;
  esac
done

# actionlint resolves the project from the surrounding git repository, so it only
# runs on a real work tree (CI, or a manual repo-root invocation). The pre-commit
# hook validates staged content from a temp tree that is not a repository, where
# the per-file YAML parse above still checks each workflow's syntax and actionlint
# defers to the File Validation CI job.
if [ -d .github/workflows ] && command -v actionlint > /dev/null 2>&1 \
  && git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  run_validation ".github/workflows" "GitHub Actions validation" actionlint
fi

if [ -s "$validation_errors" ]; then
  echo "validate-files: file validation failed:" >&2
  cat "$validation_errors" >&2
  exit 1
fi
