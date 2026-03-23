#!/bin/bash
set -euo pipefail

BIN_DIR="$(pwd)/bin"

REVIVE_PK="5fb92d6e98884f76de468fa3f6278f8807c48bebc13595d45af5bdc4da702133"
REVIVE_ADDRESS="0xf24FF3a9CF04c71Dbc94D0b566f7A27B94566cac"

ANVIL="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
ANVIL_ADDRESS="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

WALLET_PASSWORD="123456"

SUBMODULES=(
  "forge-std:v1.12.0:https://github.com/foundry-rs/forge-std.git"
  "openzeppelin-contracts:v5.5.0:https://github.com/OpenZeppelin/openzeppelin-contracts.git"
  "openzeppelin-contracts-upgradeable:v5.5.0:https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable.git"
  "openzeppelin-foundry-upgrades:v0.4.0:https://github.com/OpenZeppelin/openzeppelin-foundry-upgrades.git"
  "halmos-cheatcodes:main:https://github.com/a16z/halmos-cheatcodes.git"
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
  local ref="$2"
  local url="$3"
  local target="lib/$name"

  echo "  → Processing $name..."
  
  remove_dir_cross_platform "$target"
  
  if [[ "$name" == openzeppelin* ]]; then
    git clone "$url" "$target"
    (
      cd "$target" || exit 1
      git fetch --tags origin
      git checkout -f "$ref"
      git reset --hard "$ref"
    )
  else
    if git clone --depth 1 --branch "$ref" "$url" "$target" 2>/dev/null; then
      echo "  ✓ $name@$ref installed (shallow)"
    else
      git clone "$url" "$target"
      (
        cd "$target" || exit 1
        if git rev-parse --verify "refs/tags/$ref" >/dev/null 2>&1; then
          git checkout -f "tags/$ref"
        elif git rev-parse --verify "refs/remotes/origin/$ref" >/dev/null 2>&1; then
          git checkout -f "$ref"
        elif git rev-parse --verify "$ref" >/dev/null 2>&1; then
          git checkout -f "$ref"
        else
          echo "  ✗ Reference '$ref' not found in $name"
          exit 1
        fi
        git reset --hard HEAD
      ) || {
        echo "  ✗ Failed to checkout $ref in $name"
        exit 1
      }
    fi
  fi
  
  echo "  ✓ $name@$ref installed"
}

init_submodules(){
  echo "Installing dependencies (forced clean install)..."

  mkdir -p lib

  local processed=""
  
  for entry in "${SUBMODULES[@]}"; do
    IFS=':' read -r name ref url <<< "$entry"
    
    if echo "$processed" | grep -q "^${name}\$"; then
      echo "  ⊘ Skipping duplicate: $name"
      continue
    fi
    
    clone_and_checkout "$name" "$ref" "$url"
    processed="${processed}${name}"$'\n'
  done
}

setup_wallet() {
  local wallet_name="$1"
  local private_key="$2"
  local address="$3"
  local keystore_dir="${FOUNDRY_KEYSTORES_DIR:-$HOME/.foundry/keystores}"
  local keystore_path="$keystore_dir/$wallet_name"

  if [ -f "$keystore_path" ]; then
    echo "  ℹ Wallet '$wallet_name' already exists (address: $address)"
    return 0
  fi

  cast wallet import "$wallet_name" --private-key "$private_key" --unsafe-password "$WALLET_PASSWORD"
  echo "  ✓ Wallet '$wallet_name' created (address: $address)"
}

setup_foundry_wallet(){
  echo "Setting up Foundry wallets..."

  if ! command -v cast >/dev/null 2>&1; then
    echo "WARNING: 'cast' command not found. Install Foundry: https://getfoundry.sh"
    return 0
  fi

  setup_wallet "revive" "$REVIVE_PK" "$REVIVE_ADDRESS"
  setup_wallet "anvil-polkadot" "$ANVIL" "$ANVIL_ADDRESS"
}

check_missing_files(){
  echo "Checking for missing source files..."
  
  if [ ! -f "contracts/utils/StringUtils.sol" ]; then
    echo "  ⚠ Missing: contracts/utils/StringUtils.sol"
    echo "  → You need to create this file or restore it from your repository"
  fi
}

init_submodules
setup_foundry_wallet
check_missing_files
echo "Setup complete!"