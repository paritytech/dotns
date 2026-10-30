#!/usr/bin/env bash
set -euo pipefail

# Waits until the revive ETH-RPC adapter is ready to serve a BROADCASTER, which is a stronger
# claim than answering RPC. The socket opens before the adapter has subscribed to its node and
# filled its block cache, and in that window simple calls pass through while anything touching
# the block index answers "Ethereum block not found". A forge script hits the index in its first
# seconds, so readiness here means: the latest block resolves with a full body, and the number
# has advanced at least once while we watched, proving the subscription is live and filling.

RPC_URL="${1:-http://127.0.0.1:8545}"

rpc() {
  curl -sf -X POST -H "Content-Type: application/json" --data "$1" "$RPC_URL"
}

latest_number() {
  rpc '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' \
    | python3 -c 'import sys,json
r=json.load(sys.stdin).get("result")
print(int(r["number"],16) if r and r.get("number") else -1)' 2>/dev/null || echo -1
}

first=-1
for i in $(seq 1 120); do
  n="$(latest_number)"
  if [ "$n" -ge 0 ]; then
    if [ "$first" -lt 0 ]; then
      first="$n"
      echo "eth-rpc serving blocks after ${i}s, at #${n}; waiting for it to advance"
    elif [ "$n" -gt "$first" ]; then
      echo "eth-rpc ready after ${i}s, block #${first} advanced to #${n}"
      exit 0
    fi
  fi
  sleep 1
done

echo "eth-rpc failed to become broadcast-ready"
docker compose logs
exit 1
