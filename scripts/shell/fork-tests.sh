#!/usr/bin/env bash
set -euo pipefail

# Single-command fork-test runner. Brings up the local revive ETH-RPC adapter (or
# reuses one already answering on the RPC url), waits for it to be healthy, does a
# clean build, then runs the test/fork/** suite against it. Fork tests validate each
# upgrade script against live Paseo Asset Hub state; see CONTRIBUTING.md (Upgrade-PR
# workflow) and DEPLOYMENTS.md (Local ETH-RPC adapter). Between upgrade PRs test/fork
# is empty and the suite runs zero tests, which is a pass.
#
# Usage:
#   bun run test:fork                 # default verbosity (-vvv)
#   bun run test:fork -- -vvvvv       # pass extra forge args through
#   RPC_URL=http://127.0.0.1:8545 bun run test:fork

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"

adapter_is_up() {
  curl -sf -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
    "$RPC_URL" > /dev/null 2>&1
}

if adapter_is_up; then
  echo "fork-tests: reusing the ETH-RPC adapter already answering on $RPC_URL"
else
  echo "fork-tests: starting the eth-rpc adapter (docker compose up --build -d eth-rpc)"
  docker compose up --build -d eth-rpc
  scripts/shell/wait-for-eth-rpc.sh "$RPC_URL"
fi

# The OpenZeppelin upgrade validator reads Foundry build-info, and a stale incremental
# build trips it with "Found multiple contracts with name ...". Start from a clean
# build so every upgrade script's storage-layout diff resolves against fresh artefacts.
echo "fork-tests: forge clean"
forge clean

echo "fork-tests: running test/fork/** against $RPC_URL"
forge test --match-path 'test/fork/**' "${@:--vvv}"

echo "fork-tests: done. Stop the adapter with: docker compose down"
