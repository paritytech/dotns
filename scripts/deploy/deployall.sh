#!/usr/bin/env bash
#
# One-command deploy. Ensures the CREATE3 factory exists (deployed once from the
# factory key at nonce 0, a deterministic address), then runs the full pipeline
# reusing that factory. Because every dotNS address derives from the factory
# address, and the factory address is the same on every fresh chain, this
# reproduces the same address set across resets and networks.
#
# The two steps feed into each other: factory.sh prints the factory address,
# which this script passes to run.sh as CREATE3_FACTORY so DeployCore reuses it
# instead of minting a new one.
#
# Everything is configured from .env (see .env.example). ACCOUNT_NAME is the
# pipeline keystore; FACTORY_ACCOUNT is the factory keystore and defaults to
# ACCOUNT_NAME (a single-key setup). Keep the factory key single-purpose so its
# nonce stays 0 on each fresh chain.
#
# Usage:
#   bun run deploy:all

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

# Load .env so the whole flow is configured from one file. factory.sh and run.sh
# re-read it for their own account bootstrap.
ENV_FILE="${ENV_FILE:-.env}"
if [ -f "$ENV_FILE" ]; then
  # shellcheck source=/dev/null
  . "$ENV_FILE"
fi

# Factory keystore and credentials: use the factory-specific values when set (a
# dedicated key with its own password and private key), otherwise fall back to
# the pipeline values (single-key or shared-password setups).
factory_account="${FACTORY_ACCOUNT:-${ACCOUNT_NAME:-dotns-factory}}"
factory_password="${FACTORY_PASSWORD:-${ACCOUNT_PASSWORD:-}}"
factory_private_key="${FACTORY_PRIVATE_KEY:-${PRIVATE_KEY:-}}"

# 1. Deploy or confirm the CREATE3 factory, capturing its address.
factory_out=$(mktemp "${TMPDIR:-/tmp}/dotns-factory.XXXXXX")
trap 'rm -f "$factory_out"' EXIT
ACCOUNT_NAME="$factory_account" \
  ACCOUNT_PASSWORD="$factory_password" \
  PRIVATE_KEY="$factory_private_key" \
  "$here/factory.sh" "$@" | tee "$factory_out"

CREATE3_FACTORY=$(sed -n 's/^CREATE3_FACTORY=//p' "$factory_out" | tail -1)
if [ -z "${CREATE3_FACTORY:-}" ]; then
  echo "deployall: could not resolve the CREATE3 factory address from factory.sh output" >&2
  exit 1
fi
export CREATE3_FACTORY

# 2. Run the full pipeline reusing that factory (DeployCore adopts it instead of
#    minting a new one, so the pipeline key's nonce does not affect any address).
echo "=== Running pipeline reusing CREATE3 factory $CREATE3_FACTORY ==="
"$here/run.sh" "$@"
