#!/usr/bin/env bash
set -euo pipefail

# Checks every `*Old.sol` snapshot against the implementation actually deployed on the
# target network, by building the snapshot and comparing runtime bytecode.
#
# Why this exists. The OpenZeppelin validator diffs the new implementation's storage
# layout against the snapshot, so a snapshot that has drifted away from the live code
# makes every layout check meaningless while still passing: the diff is honest about
# two contracts that are not the pair being upgraded. Nothing in the build can notice,
# and a change that lives in calldata rather than storage leaves no trace in the layout
# at all. In September 2026 four snapshots on this branch described implementations
# that had been replaced in place months earlier, and the whole toolchain was green.
#
# The comparison masks two things that differ legitimately between an honest build and
# the chain: `UUPSUpgradeable.__self`, an immutable holding the implementation's own
# address, and the trailing CBOR metadata, which encodes compiler and source hashes.
# Everything else must match byte for byte.
#
# Usage:
#   scripts/shell/verify-snapshots.sh                        # against RPC_URL
#   RPC_URL=https://eth-rpc-paseo-next.polkadot.io ...
#   DOTNS_NETWORK=paseo-assethub scripts/shell/verify-snapshots.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
NETWORK="${DOTNS_NETWORK:-paseo-assethub}"

shopt -s nullglob
snapshots=(contracts/*/*Old.sol)
if [ ${#snapshots[@]} -eq 0 ]; then
  echo "verify-snapshots: no *Old.sol snapshots present, nothing to check"
  exit 0
fi

chain_id_hex="$(curl -sf -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' "$RPC_URL" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"])')"
chain_id="$((chain_id_hex))"

manifest="deployments/${NETWORK}/${chain_id}.json"
if [ ! -f "$manifest" ]; then
  echo "verify-snapshots: no manifest at $manifest for chain $chain_id" >&2
  exit 1
fi

echo "verify-snapshots: $manifest against $RPC_URL (chain $chain_id)"

forge build >/dev/null

RPC_URL="$RPC_URL" MANIFEST="$manifest" python3 - "${snapshots[@]}" <<'PY'
import json, os, sys, time, urllib.request

RPC = os.environ["RPC_URL"]
manifest = json.load(open(os.environ["MANIFEST"]))
# EIP-1967 implementation slot.
SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"


def rpc(method, params):
    # Forty-odd sequential calls, and one transient hiccup anywhere used to fail the whole
    # check, which upstream means a wasted label-approve cycle. Three attempts with a short
    # backoff absorb the blips; a genuine outage still fails, as it must.
    last = None
    for attempt in range(3):
        try:
            req = urllib.request.Request(
                RPC,
                data=json.dumps(
                    {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
                ).encode(),
                # Some public gateways reject urllib's default agent outright.
                headers={"content-type": "application/json", "user-agent": "dotns-verify-snapshots"},
            )
            return json.load(urllib.request.urlopen(req, timeout=60)).get("result")
        except Exception as error:  # noqa: BLE001 - anything transient deserves the retry
            last = error
            time.sleep(1 + 2 * attempt)
    raise last


def strip_metadata(code):
    # The last two bytes give the CBOR metadata length; drop that trailing section.
    if len(code) < 2:
        return bytes(code)
    return bytes(code[: -(int.from_bytes(code[-2:], "big") + 2)])


def deployed(name):
    """Runtime code behind `name`: the implementation if it is a proxy, else the account."""
    addr = manifest[name]
    impl = rpc("eth_getStorageAt", [addr, SLOT, "latest"])
    impl = "0x" + impl[-40:]
    code = bytes.fromhex((rpc("eth_getCode", [impl, "latest"]) or "0x")[2:])
    if code:
        return impl, code
    return addr, bytes.fromhex((rpc("eth_getCode", [addr, "latest"]) or "0x")[2:])


failures, checked, skipped = [], 0, []
for path in sys.argv[1:]:
    snapshot = os.path.basename(path)[:-4]          # DotnsRegistryOld
    subject = snapshot[:-3]                          # DotnsRegistry
    if subject not in manifest:
        # Interfaces, libraries and helper snapshots have no deployed counterpart of
        # their own; they are pulled in so the contract snapshots compile.
        skipped.append(snapshot)
        continue

    artefact = f"out/{snapshot}.sol/{snapshot}.json"
    if not os.path.exists(artefact):
        failures.append(f"{snapshot}: no build artefact at {artefact}")
        continue

    art = json.load(open(artefact))
    built = bytearray(bytes.fromhex(art["deployedBytecode"]["object"][2:]))
    impl, live = deployed(subject)
    live = bytearray(live)
    checked += 1

    if len(built) != len(live):
        failures.append(
            f"{snapshot}: {len(built)} bytes built against {len(live)} deployed at {impl}"
        )
        continue

    for refs in art["deployedBytecode"].get("immutableReferences", {}).values():
        for r in refs:
            start, length = r["start"], r["length"]
            built[start:start + length] = b"\0" * length
            live[start:start + length] = b"\0" * length

    if strip_metadata(built) != strip_metadata(live):
        failures.append(f"{snapshot}: same length but different code from {impl}")
    else:
        print(f"  ok  {snapshot} == {subject} at {impl}")

if skipped:
    print(f"  --  {len(skipped)} snapshot(s) with no deployed counterpart: {', '.join(skipped)}")

if failures:
    print("\nverify-snapshots: FAILED", file=sys.stderr)
    for f in failures:
        print(f"  {f}", file=sys.stderr)
    print(
        "\nA snapshot must reproduce the implementation currently deployed. Rebuild it from\n"
        "the source that was deployed, not from master and not from the tag: `git log` the\n"
        "proxy's upgrade history, or bisect builds against the deployed bytecode.",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"\nverify-snapshots: {checked} snapshot(s) reproduce the deployed bytecode")
PY
