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

staged_tree=""
format_before="$(mktemp)"
format_after="$(mktemp)"
cleanup() {
  rm -f "$format_before" "$format_after"
  [ -n "$staged_tree" ] && rm -rf "$staged_tree"
}
trap cleanup EXIT

# Validate the files this commit stages, against their staged (index) content
# rather than the working tree, so the check sees exactly what will be committed
# even when the working tree has since diverged. The check itself lives in
# validate-files.sh so the pre-commit and File Validation CI checks never drift;
# only the file set differs (staged here, the whole tree in CI). Deletions are
# excluded (ACMR); renames validate the new path. A repo-wide sweep on every
# commit is what made this hook slow, so that lives in CI instead.
echo "pre-commit: validating staged files"
staged=()
while IFS= read -r -d '' file; do
  staged+=("$file")
done < <(git diff --cached --name-only -z --diff-filter=ACMR)

if [ ${#staged[@]} -gt 0 ]; then
  staged_tree="$(mktemp -d)"
  # Write the index (staged) content of the staged files into the temp tree, then
  # validate there. `checkout-index` recreates the directory structure under the
  # prefix, so the paths line up with what validate-files.sh expects.
  printf '%s\0' "${staged[@]}" | git checkout-index -z --stdin --prefix="$staged_tree/"
  (cd "$staged_tree" && printf '%s\0' "${staged[@]}" | "$ROOT/scripts/shell/validate-files.sh")
fi

echo "pre-commit: running forge fmt"

git diff --binary -- . ':!lib/**' ':!node_modules/**' >"$format_before"

forge fmt
git diff --binary -- . ':!lib/**' ':!node_modules/**' >"$format_after"

if ! cmp -s "$format_before" "$format_after"; then
  echo "pre-commit: forge fmt changed files. Review and stage the formatting changes." >&2
  git diff --name-only -- . ':!lib/**' ':!node_modules/**' >&2
  exit 1
fi

# `forge build` (and its project-warning gate) runs in pre-push, not here, so a
# commit stays fast. Push still blocks on a clean build, and CI is the backstop.
echo "pre-commit: ok"
