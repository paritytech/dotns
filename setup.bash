#!/bin/bash
set -euo pipefail

BIN_DIR="$(pwd)/bin"

# External Solidity dependencies pinned by commit SHA. Tags can be
# moved on the upstream repo; commit SHAs cannot. The `tag` column is
# advisory (used in install logs) and the `sha` column is what the
# checkout actually lands on. Refresh by running `git ls-remote <url>`
# and pasting the dereferenced commit (use the `^{}` line for annotated
# tags so we record the underlying commit, not the tag object).
# Format: name|tag|sha|url
SUBMODULES=(
  "forge-std|v1.12.0|7117c90c8cf6c68e5acce4f09a6b24715cea4de6|https://github.com/foundry-rs/forge-std.git"
  "openzeppelin-contracts|v5.5.0|fcbae5394ae8ad52d8e580a3477db99814b9d565|https://github.com/OpenZeppelin/openzeppelin-contracts.git"
  "openzeppelin-contracts-upgradeable|v5.5.0|aa677e9d28ed78fc427ec47ba2baef2030c58e7c|https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable.git"
  "openzeppelin-foundry-upgrades|v0.4.0|cbce1e00305e943aa1661d43f41e5ac72c662b07|https://github.com/OpenZeppelin/openzeppelin-foundry-upgrades.git"
  "halmos-cheatcodes|main|6da4e692c357ba6d641a2e677a28298cac9f76ab|https://github.com/a16z/halmos-cheatcodes.git"
)

msg(){ printf "%s\n" "$*"; }

remove_dir_cross_platform() {
  local dir="$1"
  if [ -d "$dir" ]; then
    if command -v rm >/dev/null 2>&1; then
      rm -rf "$dir"
    else
      find "$dir" -delete 2>/dev/null || rmdir /s /q "$dir" 2>/dev/null || true
    fi
  fi
}

clone_and_checkout() {
  local name="$1"
  local tag="$2"
  local sha="$3"
  local url="$4"
  local target="lib/$name"

  echo "  → Processing $name..."

  remove_dir_cross_platform "$target"

  # Full clone + checkout-by-SHA. We cannot use `git clone --depth 1
  # --branch` here because the supply-chain pin is the commit hash, not
  # the tag name; a moved tag would silently land on a different
  # commit. Fetch everything once, hard-checkout the recorded SHA, then
  # verify HEAD matches before declaring success.
  git clone "$url" "$target"
  (
    cd "$target" || exit 1
    git fetch --tags origin
    if ! git cat-file -e "${sha}^{commit}" 2>/dev/null; then
      echo "  ✗ $name: pinned commit $sha not present in $url" >&2
      exit 1
    fi
    git checkout -f "$sha"
    git reset --hard "$sha"
    local actual
    actual=$(git rev-parse HEAD)
    if [ "$actual" != "$sha" ]; then
      echo "  ✗ $name: HEAD $actual does not match pinned $sha" >&2
      exit 1
    fi
  )

  echo "  ✓ $name@$tag installed (sha=$sha)"
}

init_submodules(){
  echo "Installing dependencies (forced clean install)..."

  mkdir -p lib

  local processed=""
  
  for entry in "${SUBMODULES[@]}"; do
    IFS='|' read -r name tag sha url <<< "$entry"

    if echo "$processed" | grep -q "^${name}\$"; then
      echo "  ⊘ Skipping duplicate: $name"
      continue
    fi

    clone_and_checkout "$name" "$tag" "$sha" "$url"
    processed="${processed}${name}"$'\n'
  done
}

apply_dependency_patches(){
  echo "Applying dependency patches..."
  bash scripts/shell/apply-oz-patches.sh
}

check_missing_files(){
  echo "Checking for missing source files..."
  
  if [ ! -f "contracts/utils/StringUtils.sol" ]; then
    echo "  ⚠ Missing: contracts/utils/StringUtils.sol"
    echo "  → You need to create this file or restore it from your repository"
  fi
}

install_git_hooks(){
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Installing git hooks..."
    git config core.hooksPath .githooks
    chmod +x .githooks/pre-commit .githooks/pre-push \
      scripts/shell/pre-commit.sh scripts/shell/pre-push.sh \
      scripts/shell/validate-files.sh
    echo "  ✓ core.hooksPath=.githooks"
  fi
}

init_submodules
apply_dependency_patches
check_missing_files
install_git_hooks
echo "Setup complete!"
