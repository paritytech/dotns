#!/usr/bin/env bash
#
# Deploys the CREATE3 factory on its own, from a dedicated single-purpose key,
# so its address stays reproducible across chain resets. Every other dotNS
# address derives from the factory address, and the factory's own address is
# nonce-derived, so a key that also runs the pipeline or upgrades cannot keep it
# stable. Deploy it here from a key that does nothing else, then pass the printed
# address to the pipeline as CREATE3_FACTORY (see the "Keeping the factory
# address stable across chain resets" section in DEPLOYMENTS.md).
#
# The script asserts the deployer is at nonce 0, so this key must be pristine.
#
# Usage:
#   bun run deploy:factory
#   ACCOUNT_NAME=dotns-factory RPC_URL=paseo bun run deploy:factory
#
# Env vars are the same as the main deploy runner (see _account.sh); ACCOUNT_NAME
# defaults to a factory-only key so it is never the pipeline/upgrade key. Extra
# forge flags are forwarded verbatim, e.g. ./scripts/deploy/factory.sh '--timeout 1000'.

set -euo pipefail

# Default to a factory-only key so it is never reused for the pipeline or
# upgrades, which is what keeps its nonce (and therefore the factory address)
# reproducible.
: "${ACCOUNT_NAME:=dotns-factory}"

# shellcheck source=scripts/deploy/_account.sh
. "$(dirname "$0")/_account.sh"

# Forward every extra forge flag (word-split), not just the first token.
extra="$*"

# The factory address is the deterministic nonce-0 CREATE from this key, so it
# is identical on every fresh chain.
FACTORY_ADDRESS=$(cast compute-address --nonce 0 "$SENDER" | awk '{print $NF}')

# Optional guard: when EXPECTED_CREATE3_FACTORY is pinned (per network), abort if
# the resolved address differs, so a wrong or rotated key cannot silently
# relocate the whole protocol.
if [ -n "${EXPECTED_CREATE3_FACTORY:-}" ] \
  && [ "$(printf '%s' "$FACTORY_ADDRESS" | tr 'A-F' 'a-f')" != "$(printf '%s' "$EXPECTED_CREATE3_FACTORY" | tr 'A-F' 'a-f')" ]; then
  echo "Factory address $FACTORY_ADDRESS does not match EXPECTED_CREATE3_FACTORY ($EXPECTED_CREATE3_FACTORY); wrong deployer key?" >&2
  exit 1
fi

# Skip the deploy when the factory is already present. Distinguish an RPC error
# (abort) from a genuinely empty account, so a network blip does not push a
# non-pristine key into the nonce-0 deploy path and trip its assertion.
if ! existing_code=$(cast code "$FACTORY_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null); then
  echo "Could not query code at $FACTORY_ADDRESS ($RPC_URL); aborting rather than risk a duplicate deploy." >&2
  exit 1
fi

if [ "$existing_code" != "0x" ]; then
  echo "Create3Factory already present at $FACTORY_ADDRESS on chain $CHAIN_ID (skipping deploy)"
else
  echo "=== Deploying Create3Factory from '$ACCOUNT_NAME' ($SENDER) on chain $CHAIN_ID ==="
  # Broadcast flags shared with the pipeline (defined in _account.sh).
  # shellcheck disable=SC2086
  forge script scripts/deploy/DeployCreate3Factory.s.sol:DeployCreate3Factory \
    "${FORGE_DEPLOY_ARGS[@]}" \
    -vvvv $extra
fi

# Machine-parseable line consumed by deployall.sh.
echo "CREATE3_FACTORY=$FACTORY_ADDRESS"
