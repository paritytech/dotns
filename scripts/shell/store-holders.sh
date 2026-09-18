#!/usr/bin/env bash
set -euo pipefail

# Prints every address holding a `LabelStore` on a deployed factory, as the comma-separated
# list `MigrateStoreFactory.s.sol` expects in `DOTNS_STORE_USERS`.
#
# The list has to be built off chain. The deployed factory keeps a `user => store` mapping and
# an append-only list of store addresses, and neither can be walked: the mapping has no
# enumeration, and the list holds stores, which do not know which user they belong to. What does
# carry the pairing is `LabelStoreDeployed(address indexed user, address indexed store)`, emitted
# on every deployment, so the holders are recovered by replaying that log.
#
# Read it immediately before broadcasting the migration, never from an earlier run. The factory
# is live and the count moves: it went from 57 to 58 during a single afternoon of preparing this
# upgrade. `importStores` asserts the list against the factory's own count and reverts on a short
# one, so a stale list fails the migration rather than silently omitting users, but re-reading is
# what avoids the wasted broadcast.
#
# Point RPC_URL at an archive node or an indexer, not at the public gateway. As of September 2026
# `https://eth-rpc-paseo-next.polkadot.io` answers `eth_getLogs` with an empty result for every
# range rather than an error, so a replay against it recovers nothing while looking like it
# worked. That is the failure the count check below exists to turn into a stop, and it is why
# this script refuses to print a list it cannot reconcile. Blockscout at
# `https://blockscout-paseo-next.polkadot.io` indexes the same chain and serves the logs.
#
# Usage:
#   RPC_URL=... scripts/shell/store-holders.sh 0x709A027F446a9e2a4BB9cb9a9c754435b19e32B7
#   DOTNS_STORE_USERS="$(RPC_URL=... scripts/shell/store-holders.sh 0x...)"

FACTORY="${1:?usage: store-holders.sh <factory address>}"
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
FROM_BLOCK="${FROM_BLOCK:-0}"

# keccak("LabelStoreDeployed(address,address)")
TOPIC=0x6294914f6f12fb260c6b69d8a5435317a9318b45790f0b19b42cdd06708fcdea

logs="$(curl -sf -X POST -H 'Content-Type: application/json' --data "$(cat <<JSON
{"jsonrpc":"2.0","id":1,"method":"eth_getLogs","params":[{
  "address":"${FACTORY}",
  "topics":["${TOPIC}"],
  "fromBlock":"${FROM_BLOCK}",
  "toBlock":"latest"
}]}
JSON
)" "$RPC_URL")"

echo "$logs" | FACTORY="$FACTORY" RPC_URL="$RPC_URL" python3 -c '
import json, os, sys, urllib.request

result = json.load(sys.stdin)
if "error" in result:
    sys.exit("store-holders: RPC error: " + json.dumps(result["error"]))

# topics[1] is the indexed user, left-padded to 32 bytes.
users = []
for log in result["result"]:
    user = "0x" + log["topics"][1][-40:]
    if user not in users:
        users.append(user)


def rpc(method, params):
    req = urllib.request.Request(
        os.environ["RPC_URL"],
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        headers={"content-type": "application/json", "user-agent": "dotns-store-holders"},
    )
    return json.load(urllib.request.urlopen(req, timeout=60)).get("result")


# The factory counts stores, so the recovered holders must match it exactly. A mismatch means the
# replay missed logs, which is what a pruned node or a truncated block range produces, and it has
# to fail here rather than at the broadcast.
selector = "0xd6fefb14"  # getLabelStoreCount()
count = int(rpc("eth_call", [{"to": os.environ["FACTORY"], "data": selector}, "latest"]), 16)
if count != len(users):
    sys.exit(
        f"store-holders: recovered {len(users)} holders but the factory reports {count} stores. "
        "Widen FROM_BLOCK or use an archive node; the replay is incomplete."
    )

print(",".join(users))
'
