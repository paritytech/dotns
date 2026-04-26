#!/usr/bin/env bash
set -euo pipefail

RPC_URL="${1:-http://127.0.0.1:8545}"

for i in $(seq 1 60); do
  if curl -sf -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "$RPC_URL" >/dev/null; then
    echo "eth-rpc ready after ${i}s"
    exit 0
  fi
  sleep 1
done

echo "eth-rpc failed to come up"
docker compose logs
exit 1