#!/bin/bash
#
# Applies the project's dependency patches under `patches/` to the matching
# `lib/<name>/` submodule trees. Idempotent: a patch already in place is detected
# via `git apply --reverse --check` and skipped.
#
# Each patch must be named `lib/<submodule>.patch` form: e.g.
# `patches/openzeppelin-contracts.patch` applies inside `lib/openzeppelin-contracts/`.
#
# Why this exists: pallet-revive's transferable-name flow needs `payable
# transferFrom`/`safeTransferFrom` on ERC721, which upstream OZ does not ship.
# Vendoring a fork would drift; instead we keep vanilla submodules pinned in
# `setup.bash`'s SUBMODULES list and patch them at install / CI time.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"

if [ ! -d "$repo_root/patches" ]; then
  echo "  ⊘ No patches/ directory; nothing to apply"
  exit 0
fi

shopt -s nullglob
patches=("$repo_root"/patches/*.patch)
shopt -u nullglob

if [ ${#patches[@]} -eq 0 ]; then
  echo "  ⊘ patches/ is empty; nothing to apply"
  exit 0
fi

for patch in "${patches[@]}"; do
  name="$(basename "$patch" .patch)"
  target="$repo_root/lib/$name"

  if [ ! -d "$target" ]; then
    echo "  ✗ Skipping $(basename "$patch"): target $target does not exist"
    continue
  fi

  (
    cd "$target" || exit 1
    if git apply --check --reverse "$patch" >/dev/null 2>&1; then
      echo "  ⊘ $name already patched"
      exit 0
    fi
    git apply --check "$patch" 2>/dev/null
    git apply "$patch"
    echo "  ✓ $name patched ($(basename "$patch"))"
  ) || {
    echo "  ✗ Failed to apply $(basename "$patch") to $target"
    exit 1
  }
done
