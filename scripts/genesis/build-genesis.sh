#!/usr/bin/env bash
set -euo pipefail

# DotNS pallet-revive genesis builder
#
# Deploys the full DotNS contract set to a local anvil, then extracts the
# resulting EVM state (bytecodes + storage) as a pallet-revive GenesisConfig
# artifact. A chain can then carry DotNS from genesis instead of deploying it
# after the fact.
#
# Output, into $1 (default ./release):
#   dotns-genesis-<tld>.json  pallet-revive GenesisConfig accounts
#
# The TLD is in the filename because it is baked into the registry initialiser: a genesis built
# with DOTNS_TLD=testnet suits a test network and nothing else, and a file called plainly
# `dotns-genesis.json` is how a test registry ends up on a chain that wanted a real one.
#
# Addresses are NOT emitted here. `release-metadata.mjs build` already publishes deployments.json
# from the committed manifests (#242), and a second copy in the same release is the duplication
# that PR deliberately removed.
#
# Requires: forge, anvil, cast (foundry), node >= 18, jq — all already present
# in the release workflow. Run it after `forge build`, from the repo root.

OUT="${1:-./release}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

ANVIL_PORT="${ANVIL_PORT:-28545}"
RPC_URL="http://127.0.0.1:$ANVIL_PORT"
ANVIL_STATE="$OUT/anvil-state.json"
GENESIS_OUT=""   # set once DOTNS_TLD is validated, below

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_FILE="deployments/localhost/31337.json"
CANONICAL_MANIFEST="deployments/paseo-assethub/420420417.json"

# Who OWNS the contracts in the genesis state (REQUIRED, one of the three below).
#
# No DotNS *address* depends on this key — with CREATE3 the addresses are a pure
# function of the factory (see FACTORY_DEPLOYER_KEY below, which owns only the
# factory) — but every ownership and role assignment written into genesis storage
# does: this key ends up owning the registry, the resolvers, the registrar, the
# store factory and the beacons.
#
# Accepted, in order of precedence:
#   DOTNS_ADMIN_KEY       a raw private key — the admin credential this repo already holds
#   DOTNS_ADMIN_MNEMONIC  the admin mnemonic; index $DOTNS_ADMIN_INDEX (default 0)
#
# Deliberately NOT accepted: DOTNS_MNEMONIC. That is an operational credential for driving
# the `dotns` CLI, not the contract admin, and quietly making it the owner of every
# contract in a genesis would be a hard mistake to spot.
# Not DEPLOYER_KEY: that name is dotns-releases' own secret, and accepting it here
# would make which key owns a published genesis depend on which repo the build ran in.
ADMIN_KEY="${DOTNS_ADMIN_KEY:-}"

# Single-purpose CREATE3 factory deployer key (REQUIRED). Every DotNS address is
# a pure function of the Create3Factory address, and the factory address is
# keccak(deployer, nonce 0) — see "Deterministic addresses (CREATE3)" in
# DEPLOYMENTS.md. Deploying the factory from this key as its first transaction is
# what makes the genesis addresses equal the live ones, which is asserted below.
FACTORY_DEPLOYER_KEY="${FACTORY_DEPLOYER_KEY:-}"

# TLD the genesis registry initialises with. Required by DeployCore, which reads
# it to build the registry initialiser and reverts when unset. Validated as a
# single lowercase DNS label so a bad value fails here rather than deep inside a
# forge stage. This does not affect any address — only registry storage — but it
# does decide which networks the resulting genesis is fit for, so it ends up in
# the output filename.
export DOTNS_TLD="${DOTNS_TLD:-testnet}"
if ! printf '%s' "$DOTNS_TLD" | grep -Eq '^[a-z]{2,63}$'; then
    echo "Error: DOTNS_TLD ('$DOTNS_TLD') must be 2 to 63 lowercase ASCII letters (a-z)" >&2
    exit 1
fi

GENESIS_OUT="$OUT/dotns-genesis-$DOTNS_TLD.json"

echo "=== DotNS genesis builder ==="
echo "Building a genesis for TLD .$DOTNS_TLD -> $(basename "$GENESIS_OUT")"
echo ""

# ---- Pre-flight ----
for tool in forge anvil cast node jq curl; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Error: $tool is not on PATH" >&2; exit 1; }
done

# Needs cast, so it happens after the check above.
if [ -z "$ADMIN_KEY" ] && [ -n "${DOTNS_ADMIN_MNEMONIC:-}" ]; then
    ADMIN_KEY="$(cast wallet private-key --mnemonic "$DOTNS_ADMIN_MNEMONIC" "${DOTNS_ADMIN_INDEX:-0}")"
    echo "Owner key derived from DOTNS_ADMIN_MNEMONIC, index ${DOTNS_ADMIN_INDEX:-0}."
fi

if [ -z "$ADMIN_KEY" ]; then
    cat >&2 <<'MSG'
Error: no owner key. Set DOTNS_ADMIN_KEY or DOTNS_ADMIN_MNEMONIC.

Whichever is given becomes the owner of every DotNS contract in the genesis
state, so this build refuses to fall back to a public dev key.
MSG
    exit 1
fi
if [ -z "$FACTORY_DEPLOYER_KEY" ]; then
    cat >&2 <<'MSG'
Error: FACTORY_DEPLOYER_KEY is required.

Every genesis address derives from the Create3Factory deployed by this key, so
without it the artifact would carry a different address set than the live
deployment and the parity check below would fail anyway.
MSG
    exit 1
fi

DEPLOYER_ADDR="$(cast wallet address --private-key "$ADMIN_KEY")"
echo "Contract owner:      $DEPLOYER_ADDR"
echo "TLD:                 .$DOTNS_TLD"
echo ""

# ---- anvil ----
cleanup() {
    if [ -n "${ANVIL_PID:-}" ]; then kill "$ANVIL_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

echo "Starting anvil on port $ANVIL_PORT..."
# The wait loop after shutdown only tests that this file is non-empty, so a dump left by
# an interrupted run would satisfy it instantly and be parsed as if it were this one.
rm -f "$ANVIL_STATE"
# Kept out of $OUT: that directory is what the release uploads, and a debug log has no
# business being a candidate for it. Left behind on purpose — it is the only record of
# why a stage failed.
ANVIL_LOG="${TMPDIR:-/tmp}/dotns-genesis-anvil.log"
# Not --silent: the redirect below already keeps the console clean, and --silent would
# leave $ANVIL_LOG empty — which is the only thing the failure path above has to print.
anvil --port "$ANVIL_PORT" --dump-state "$ANVIL_STATE" > "$ANVIL_LOG" 2>&1 &
ANVIL_PID=$!

# Probe over plain JSON-RPC rather than with `cast`. cast parses foundry.toml on every
# invocation, so a config key its build does not recognise makes it exit non-zero before it
# ever reaches the network — which reads here as "anvil never started" while anvil is in fact
# healthy. Seen for real with `ignored_error_codes` on a foundry version that predates one of
# the entries. curl has no opinion about foundry config.
ready() {
    curl -sf -m 3 -X POST "$RPC_URL" \
        -H 'content-type: application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
        2>/dev/null | grep -q '"result"'
}
for _ in $(seq 1 60); do
    if ready; then break; fi
    # Fail fast if it died rather than waiting out the whole timeout on a corpse.
    if ! kill -0 "$ANVIL_PID" 2>/dev/null; then break; fi
    sleep 1
done
if ! ready; then
    echo "Error: anvil did not become ready on $RPC_URL" >&2
    echo "--- anvil output ---" >&2
    cat "$ANVIL_LOG" >&2 || true
    exit 1
fi
echo "  ✓ anvil ready"
echo ""

# ---- Deploy ----
# Multi-stage: DotnsDeployer is split into five stages so each `forge script`
# invocation is its own EVM simulation, capping forge's per-tx memory accounting
# (the single-shot variant hits MemoryOOG with the current contract set).
#
# One `forge build` BEFORE the loop, and none inside it: otherwise each stage's
# `forge script` emits its own build-info file and OpenZeppelin's upgrade-safety
# validator fails with "multiple contracts found". The clean build is repeated
# here rather than inherited from an earlier step so this script is correct on
# its own, whatever ran before it.
echo "Building contracts..."
forge clean
forge build
echo ""

# Deploy the Create3Factory from the single-purpose key at nonce 0 so it lands on
# the canonical address, then hand it to the stages via CREATE3_FACTORY (read by
# BaseDeployer._configuredCreate3Factory).
FACTORY_DEPLOYER="$(cast wallet address --private-key "$FACTORY_DEPLOYER_KEY")"
CREATE3_FACTORY="$(cast compute-address "$FACTORY_DEPLOYER" --nonce 0 | awk '{print $NF}')"
export CREATE3_FACTORY
echo "=== Create3Factory from $FACTORY_DEPLOYER -> $CREATE3_FACTORY ==="

# Neither key is a prefunded anvil account; give both 1000 ETH.
cast rpc anvil_setBalance "$FACTORY_DEPLOYER" 0x3635C9ADC5DEA00000 --rpc-url "$RPC_URL" >/dev/null
cast rpc anvil_setBalance "$DEPLOYER_ADDR" 0x3635C9ADC5DEA00000 --rpc-url "$RPC_URL" >/dev/null

forge script scripts/deploy/DeployCreate3Factory.s.sol:DeployCreate3Factory \
    --rpc-url "$RPC_URL" \
    --private-key "$FACTORY_DEPLOYER_KEY" \
    --sender "$FACTORY_DEPLOYER" \
    --broadcast \
    --slow

# The stage list is read out of scripts/deploy/run.sh rather than repeated here. A copy would
# go stale the first time a stage is added or reordered, and the failure mode is the worst kind:
# a genesis that builds cleanly and is quietly missing whatever the new stage wired up. If the
# array cannot be parsed the build stops instead of guessing.
# `|| true` matters: grep exits 1 when it matches nothing, and under `set -o pipefail`
# that killed the assignment before the check below could explain what went wrong.
STAGES=$(sed -n '/^stages=(/,/^)/p' scripts/deploy/run.sh | sed '1d;$d' | tr -d ' \t' | grep -v '^$' || true)
if [ -z "$STAGES" ]; then
    echo "Error: could not read the stage list from scripts/deploy/run.sh." >&2
    echo "       That file defines the deploy stages; this build follows it rather than" >&2
    echo "       keeping a second copy. Check whether its \`stages=(...)\` array moved." >&2
    exit 1
fi
echo "Stages, from scripts/deploy/run.sh: $(printf '%s ' $STAGES)"

# NOTE for anyone collapsing this into `bun run deploy:all` (which does the same deploy, with
# a factory-exists check and an EXPECTED_CREATE3_FACTORY guard this does not have): that flow
# takes its pipeline signer from PRIVATE_KEY, and .github/workflows/deploy-contracts.yml sets
# it to anvil test account 7 — a documented public key. That is correct there, because that
# job only checks addresses, which do not depend on the signer. It is NOT correct here: this
# signer becomes the owner of every contract in the genesis storage, so it must stay the admin
# key. Substituting the test key would hand control of a published genesis to a key printed in
# Foundry's docs.
echo "=== Baking TLD .$DOTNS_TLD into the genesis registry ==="
for stage in $STAGES; do
    echo "  === $stage ==="
    forge script "scripts/deploy/${stage}.s.sol:${stage}" \
        --rpc-url "$RPC_URL" \
        --private-key "$ADMIN_KEY" \
        --sender "$DEPLOYER_ADDR" \
        --broadcast \
        --slow
done
echo ""

[ -f "$DEPLOYMENT_FILE" ] \
    || { echo "Error: no deployment manifest at $DEPLOYMENT_FILE — a stage failed above" >&2; exit 1; }

# ---- Address parity with the live deployment ----
# The committed manifest is the only source of truth for DotNS addresses, so this is a
# hard failure, not a warning: a genesis built from a different factory key carries a
# different address set, and nothing downstream would notice.
#
# Underscore-prefixed keys are metadata rather than contracts (`_seed`, and
# `_deployedFrom` once dotns-releases#12 lands), so they are filtered by prefix.
#
# Compared entry-by-entry: the local manifest may carry newer contracts not yet deployed
# live, so only the canonical entries are asserted.
#
if [ ! -f "$CANONICAL_MANIFEST" ]; then
    echo "Error: no canonical manifest at $CANONICAL_MANIFEST." >&2
    echo "       Addresses cannot be verified, so the genesis would ship unchecked." >&2
    exit 1
fi

echo "Verifying address parity with $CANONICAL_MANIFEST..."
EXPECTED=$(jq -r 'with_entries(select(.key | startswith("_") | not)) | to_entries | sort_by(.key)[]
    | "\(.key)=\(.value | ascii_downcase)"' "$CANONICAL_MANIFEST")
ACTUAL=$(jq -r --slurpfile canon "$CANONICAL_MANIFEST" '
    with_entries(select(.key | startswith("_") | not))
    | with_entries(select($canon[0][.key] != null))
    | to_entries | sort_by(.key)[]
    | "\(.key)=\(.value | ascii_downcase)"' "$DEPLOYMENT_FILE")
if ! diff -u -L "expected ($CANONICAL_MANIFEST)" -L "actual (this build)" \
        <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$ACTUAL"); then
    {
        echo "Error: the deploy no longer reproduces the committed address set."
        echo "       Lines marked -/+ above differ from $CANONICAL_MANIFEST."
        echo ""
        echo "       Two things cause this:"
        echo "         * FACTORY_DEPLOYER_KEY is not the key the live factory came from."
        echo "           Every DotNS address derives from the factory address, which is"
        echo "           keccak(deployer, nonce 0), so a different key moves all of them."
        echo "         * A salt or a label moved for one contract. Only that contract's"
        echo "           line differs; update $CANONICAL_MANIFEST, or restore the label."
    } >&2
    exit 1
fi
echo "  ✓ all live addresses reproduced ($(jq 'with_entries(select(.key | startswith("_") | not)) | length' "$CANONICAL_MANIFEST") contracts)"
echo ""

# ---- Dump anvil state and extract ----
# anvil writes --dump-state only on shutdown.
echo "Stopping anvil to flush its state dump..."
kill "$ANVIL_PID" 2>/dev/null || true
# Wait for the process to actually exit, not just for the file to appear. The dump is
# several MB and written during shutdown, so `-s` alone goes true on the first byte and
# the extractor would parse a truncated file.
wait "$ANVIL_PID" 2>/dev/null || true
for _ in $(seq 1 30); do
    [ -s "$ANVIL_STATE" ] && break
    sleep 1
done
ANVIL_PID=""
[ -s "$ANVIL_STATE" ] \
    || { echo "Error: anvil wrote no state to $ANVIL_STATE" >&2; exit 1; }

node "$SCRIPT_DIR/extract-genesis.mjs" \
    --state "$ANVIL_STATE" \
    --deployments "$DEPLOYMENT_FILE" \
    --output "$GENESIS_OUT" \
    --tld "$DOTNS_TLD"

rm -f "$ANVIL_STATE"

echo ""
echo "=== Done ==="
echo "  $GENESIS_OUT"
echo "      registry TLD .$DOTNS_TLD — this genesis is only for a network that wants that TLD"
echo "      contract addresses: see deployments.json, published by release-metadata.mjs"
