#!/usr/bin/env bash
#
# Runs the multi-stage DotNS deploy pipeline in order.
#
# Each stage is its own `forge script` invocation (therefore its own EVM
# simulation), so OpenZeppelin's upgrade-safety validator's cumulative memory
# gas cannot spill across stages. Splitting the pipeline is the only way to
# keep every OZ check intact while the contract set grows.
#
# Usage:
#   run.sh <foundry-account> <sender-address> [extra-forge-flags]
#
# Example:
#   run.sh anvil-polkadot 0xf39Fd6e5... '--slow'
#
# The `<extra-forge-flags>` argument is forwarded verbatim to every stage.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <account> <sender> [extra-forge-flags]" >&2
  exit 1
fi

account="$1"
sender="$2"
extra="${3:-}"

common=(
  --rpc-url paseo_local
  --account "$account"
  --password 123456
  --sender "$sender"
  --broadcast
  -vvvvv
)

stages=(
  DeployCore
  DeployRecords
  DeployPolicy
  DeployPopSystem
  WireDeployments
)

for stage in "${stages[@]}"; do
  echo "=== Running $stage ==="
  # shellcheck disable=SC2086
  forge script "scripts/deploy/${stage}.s.sol:${stage}" "${common[@]}" $extra
done

echo "=== Pipeline complete ==="
