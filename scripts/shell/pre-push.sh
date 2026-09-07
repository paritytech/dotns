#!/usr/bin/env bash
set -euo pipefail

# Source the shared PATH augmentation FIRST, before any git call, via a
# git-independent path: GUI clients (GitHub Desktop) can spawn the hook with a
# minimal environment where git itself is not on the bare PATH, which is the
# case this augmentation exists to fix.
# shellcheck source=scripts/shell/lib-hook-env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-hook-env.sh"

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

build_log="$(mktemp)"
project_warnings="$(mktemp)"
cleanup() {
  rm -f "$build_log" "$project_warnings"
}
trap cleanup EXIT

# The build gate lives here rather than in pre-commit so a commit stays fast. A
# push blocks on a clean build with no project-code warnings, and CI is the
# final backstop.
echo "pre-push: running forge build"
if ! forge build >"$build_log" 2>&1; then
  cat "$build_log" >&2
  exit 1
fi

awk '
  function flush() {
    if (!in_warning) {
      return
    }

    if (project_warning) {
      printf "%s", block
    }

    block = ""
    in_warning = 0
    has_path = 0
    project_warning = 0
  }

  /^Warning / {
    flush()
    in_warning = 1
  }

  in_warning {
    block = block $0 "\n"
    if ($0 ~ /^[[:space:]]*-->[[:space:]]+[^:]+:/) {
      path = $0
      sub(/^[[:space:]]*-->[[:space:]]+/, "", path)
      sub(/:.*/, "", path)
      has_path = 1
      if (path !~ /(^|\/)(lib|node_modules)\//) {
        project_warning = 1
      }
    }
  }

  END {
    flush()
  }
' "$build_log" >"$project_warnings"

if [ -s "$project_warnings" ]; then
  echo "pre-push: forge build emitted warnings from project code:" >&2
  cat "$project_warnings" >&2
  echo "pre-push: address these warnings before pushing." >&2
  exit 1
fi

echo "pre-push: ok"
