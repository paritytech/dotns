#!/usr/bin/env bash
#
# Runs the multi-stage DotNS deploy pipeline against a Foundry keystore
# wallet. `.env` is a one-off bootstrap file: it carries PRIVATE_KEY and
# ACCOUNT_PASSWORD only long enough to import the wallet into the
# Foundry keystore on the first run, after which the file is deleted so
# no plaintext secrets persist on disk. Subsequent runs prompt for the
# keystore password interactively and rely on sensible defaults for
# everything else; nothing sensitive ever sits in a file between
# deploys. A failed run leaves `.env` exactly as it was for correction
# and retry.
#
# Local usage:
#   1. cp .env.example .env
#   2. set PRIVATE_KEY and ACCOUNT_PASSWORD in .env (and adjust
#      ACCOUNT_NAME or RPC_URL if the defaults are
#      not what you want)
#   3. bun run deploy   (or ./scripts/deploy/run.sh)
#   4. on success, the script deletes .env automatically
#   5. for every subsequent run, just `bun run deploy`; you will be
#      prompted for the keystore password
#
# CI / scripted usage (no `.env`):
#   PRIVATE_KEY=0x... ACCOUNT_PASSWORD=... ./scripts/deploy/run.sh '--slow'
#
# Each stage runs as its own `forge script` invocation (therefore its
# own EVM simulation), so OpenZeppelin's upgrade-safety validator's
# cumulative memory gas cannot spill across stages.
#
# Env vars (read from `.env` if present, otherwise from the shell):
#   ACCOUNT_NAME       Foundry keystore account passed to forge as --account.
#                      Defaults to `dotns-deploy`.
#   ACCOUNT_PASSWORD   Password passed to cast/forge as --password. Prompted
#                      interactively when not set.
#   PRIVATE_KEY        Hex-encoded deployer private key, with or without 0x.
#                      Required only when ACCOUNT_NAME has not yet been
#                      imported into the Foundry keystore.
#   RPC_URL            Foundry rpc alias (see [rpc_endpoints] in foundry.toml)
#                      or full https/wss URL. Defaults to `paseo_local`.
#   ENV_FILE           Path to env file. Defaults to `.env`.
#
# Extra forge flags are forwarded verbatim to every stage, e.g.
#   ./scripts/deploy/run.sh '--slow --timeout 1000'

set -euo pipefail

# Resolve the deployer keystore account, RPC alias, broadcasting address, and
# chain id (importing from a one-off .env on first run). Shared with the factory
# deploy so both use identical account handling.
# shellcheck source=scripts/deploy/_account.sh
. "$(dirname "$0")/_account.sh"

# Pipeline-only default; .env has already been loaded by _account.sh.

# TLD the protocol registry initialises with. DeployCore reads it through
# vm.envString("DOTNS_TLD"), so it has to be exported: sourcing .env does not
# auto-export, matching DEPLOYMENT_NETWORK below. No default is applied; a
# missing TLD must abort in the Solidity stage rather than silently land the
# wrong one, which no setter can correct afterwards.
if [ -n "${DOTNS_TLD:-}" ]; then
  export DOTNS_TLD
fi

# Forward every extra forge flag (word-split), not just the first token.
extra="$*"

if [ "${DOTNS_DEPLOY_SKIP_CLEAN_BUILD:-0}" != "1" ]; then
  echo "=== Rebuilding full Foundry artifacts for OpenZeppelin validation ==="
  forge clean
  forge build
fi

# Manifest subdirectory. Two chains can present the same chain id (for example
# a previewnet and a next environment both reached through the local ETH-RPC
# adapter); chain id alone then aliases their manifests onto one file, so a
# later deploy silently overwrites an earlier one. DEPLOYMENT_NETWORK names the
# subdirectory explicitly so each upstream keeps its own manifest. When unset,
# fall back to the chain-id default, which must match DeploymentNetwork.folder
# on the Solidity side. The variable is exported (only when set) so every forge
# stage resolves the same folder through BaseDeployer.networkFolder.
if [ -n "${DEPLOYMENT_NETWORK:-}" ]; then
  DEPLOYMENT_FOLDER="$DEPLOYMENT_NETWORK"
  export DEPLOYMENT_NETWORK
else
  unset DEPLOYMENT_NETWORK
  case "$CHAIN_ID" in
    420420422) DEPLOYMENT_FOLDER="passethub-testnet" ;;
    420420417) DEPLOYMENT_FOLDER="paseo-assethub" ;;
    420420420) DEPLOYMENT_FOLDER="paseo-local" ;;
    *) DEPLOYMENT_FOLDER="localhost" ;;
  esac
fi

# Reuse a pre-deployed CREATE3 factory when its address is supplied. Every DotNS
# address derives from the factory address, and the factory's own address is
# nonce-derived, so a key that also runs upgrades cannot keep it stable across
# chain resets. Deploy the factory once from a single-purpose key at nonce 0
# (scripts/deploy/DeployCreate3Factory.s.sol) and export its address as
# CREATE3_FACTORY; DeployCore then reuses it instead of minting a new one, so
# the pipeline key's nonce no longer affects any address. Exported (only when
# set) so every forge stage resolves it through BaseDeployer.
if [ -n "${CREATE3_FACTORY:-}" ]; then
  export CREATE3_FACTORY
else
  unset CREATE3_FACTORY
fi

MANIFEST_PATH="deployments/$DEPLOYMENT_FOLDER/$CHAIN_ID.json"
mkdir -p "$(dirname "$MANIFEST_PATH")"

backup_manifest() {
  local backup
  backup=$(mktemp "${TMPDIR:-/tmp}/dotns-manifest.${CHAIN_ID}.XXXXXX")
  if [ -f "$MANIFEST_PATH" ]; then
    cp "$MANIFEST_PATH" "$backup"
    echo "$backup"
  else
    rm -f "$backup"
    echo ""
  fi
}

restore_manifest() {
  local backup="$1"
  if [ -n "$backup" ]; then
    cp "$backup" "$MANIFEST_PATH"
  else
    rm -f "$MANIFEST_PATH"
  fi
}

validate_manifest_contracts() {
  if [ ! -f "$MANIFEST_PATH" ]; then
    echo "Manifest missing after stage: $MANIFEST_PATH" >&2
    return 1
  fi

  local failed=0
  while read -r name addr; do
    [ -n "$name" ] || continue
    code=$(cast code "$addr" --rpc-url "$RPC_URL")
    if [ "$code" = "0x" ]; then
      echo "Manifest address has no code: $name=$addr" >&2
      failed=1
    fi
  done < <(
    jq -r '
      to_entries[]
      | select(.key != "_seed")
      | select(.value != "0x0000000000000000000000000000000000000000")
      | "\(.key) \(.value)"
    ' "$MANIFEST_PATH"
  )

  return "$failed"
}

if [ "${DOTNS_DEPLOY_KEEP_MANIFEST:-0}" != "1" ] && [ -f "$MANIFEST_PATH" ]; then
  ARCHIVE_PATH="${MANIFEST_PATH}.pre-fresh.$(date +%Y%m%d%H%M%S)"
  cp "$MANIFEST_PATH" "$ARCHIVE_PATH"
  rm -f "$MANIFEST_PATH"
  echo "Archived existing manifest for fresh deploy: $ARCHIVE_PATH"
fi

# Broadcast flags shared with factory.sh (defined in _account.sh); each stage
# also gets full verbosity.
common=("${FORGE_DEPLOY_ARGS[@]}" -vvvvv)

stages=(
  DeployCore
  DeployRecords
  DeployPolicy
  DeployPopSystem
  WireDeployments
)

for stage in "${stages[@]}"; do
  echo "=== Running $stage ==="
  manifest_backup=$(backup_manifest)
  # shellcheck disable=SC2086
  if ! forge script "scripts/deploy/${stage}.s.sol:${stage}" "${common[@]}" $extra; then
    restore_manifest "$manifest_backup"
    echo "Restored manifest after failed stage: $stage" >&2
    exit 1
  fi
  if ! validate_manifest_contracts; then
    restore_manifest "$manifest_backup"
    echo "Restored manifest after invalid stage output: $stage" >&2
    exit 1
  fi
  # Stage succeeded; drop its rollback backup so successful runs leave no temp files.
  [ -n "$manifest_backup" ] && rm -f "$manifest_backup"
done

echo "=== Pipeline complete ==="

# Delete the bootstrap env file so plaintext secrets do not persist
# between deploys. Subsequent runs prompt for the password interactively
# and rely on the defaults declared above for everything else.
if [ -f "$ENV_FILE" ]; then
  rm -f "$ENV_FILE"
  echo "Deleted one-off env file: $ENV_FILE"
fi
