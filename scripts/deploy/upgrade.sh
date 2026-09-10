#!/usr/bin/env bash
set -euo pipefail

# Broadcasts a single in-place upgrade script against the resolved deployer
# account. It reuses the shared forge flags from _account.sh (legacy, slow, and
# the gas limit matching the block gas limit) so an upgrade broadcast cannot
# drift from the deploy pipeline. The upgrade script resolves its target proxy
# from the on-disk manifest and runs the OpenZeppelin layout diff before the
# swap; the simulation is never skipped.
#
# Usage:
#   SCRIPT=UpgradeRegistrar ACCOUNT_NAME=<keystore> RPC_URL=<network> ./scripts/deploy/upgrade.sh
#
#   SCRIPT              Upgrade script name, for example UpgradeRegistrar.
#   ACCOUNT_NAME        Foundry keystore account, passed to forge as --account.
#   RPC_URL             Network RPC alias or URL, same meaning as the deploy runner.
#   DEPLOYMENT_NETWORK  Optional manifest subdirectory override, same meaning as
#                       the deploy runner.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

SCRIPT="${SCRIPT:?set SCRIPT to an upgrade script name, for example UpgradeRegistrar}"

# shellcheck source=scripts/deploy/_account.sh
. "$(dirname "$0")/_account.sh"

# Exported only when set so the forge script resolves the same manifest folder the
# deploy runner does; sourcing .env does not auto-export.
if [ -n "${DEPLOYMENT_NETWORK:-}" ]; then
  export DEPLOYMENT_NETWORK
fi

forge script "scripts/deploy/${SCRIPT}.s.sol:${SCRIPT}" "${FORGE_DEPLOY_ARGS[@]}" -vvvvv
