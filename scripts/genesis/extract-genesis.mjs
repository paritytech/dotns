#!/usr/bin/env node

/**
 * dotNS Genesis State Extractor
 *
 * Reads an anvil state dump and a dotNS deployments file, extracts all
 * contract bytecodes and storage, and outputs a JSON file compatible with
 * pallet-revive's GenesisConfig format.
 *
 * The deployments manifest only names the contracts the deploy pipeline wants
 * consumers to know about; those contracts point at further contracts that are
 * just as load-bearing (UUPS implementations behind a proxy, store
 * implementations behind an UpgradeableBeacon). Anything reachable from a named
 * contract through storage is pulled in transitively, and the result is checked
 * for dangling pointers before it is written — a genesis that names a contract
 * it does not carry the code for looks fine but reverts at the first call.
 *
 * Zero external dependencies — uses only Node.js built-ins.
 *
 * Usage:
 *   node scripts/genesis/extract-genesis.mjs \
 *     --state ./release/anvil-state.json \
 *     --deployments ./deployments/localhost/31337.json \
 *     --output ./release/dotns-genesis-testnet.json
 */

import { readFileSync, writeFileSync } from "fs";
import { fileURLToPath } from "url";
import { resolve } from "path";

// EIP-1967 implementation storage slot
export const EIP1967_IMPL_SLOT =
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

// An UpgradeableBeacon is not a proxy and does not use the EIP-1967 slot: Ownable puts
// _owner in slot 0 and the beacon puts _implementation in slot 1.
export const BEACON_IMPL_SLOT = "0x" + "0".repeat(63) + "1";

const ZERO_ADDR = "0x" + "0".repeat(40);

// Helpers

/** Pad a hex string to N bytes (left-pad with zeros) */
export function padHex(hex, bytes) {
  const clean = hex.startsWith("0x") ? hex.slice(2) : hex;
  return "0x" + clean.padStart(bytes * 2, "0");
}

/** Normalize address to checksumless lowercase (manifests are checksummed, dumps are not) */
export function normalizeAddr(addr) {
  return addr.toLowerCase();
}

/**
 * Read a storage word as a candidate address: the low 20 bytes, or null for zero.
 *
 * Deliberately does NOT require the top 12 bytes to be zero. A pointer Solidity
 * packed beside a smaller value in the same slot has a dirty prefix and would be
 * missed. Every candidate is filtered by `referencedContracts` for actual code, so
 * a word that is really a hash or a balance is dropped there — the cost of being
 * permissive here is a few extra lookups, and the cost of being strict is a
 * silently absent implementation contract.
 */
export function addressFromWord(word) {
  if (typeof word !== "string") return null;
  const clean = padHex(word, 32).slice(2);
  if (clean.length !== 64) return null;
  const addr = "0x" + clean.slice(24);
  return addr === ZERO_ADDR ? null : addr;
}

/**
 * Every contract that `acct` points at through its storage. Words that resolve
 * to an EOA (an owner, an operator, a role holder) are not references we can
 * follow — only accounts that carry code are.
 */
export function referencedContracts(acct, stateAccounts) {
  const refs = [];
  for (const [slot, word] of Object.entries(acct?.storage ?? {})) {
    const addr = addressFromWord(word);
    if (!addr) continue;
    const target = stateAccounts[addr];
    if (!target || !target.code || target.code === "0x") continue;
    refs.push({ address: addr, slot: padHex(slot, 32) });
  }
  return refs;
}

/** Human-readable name for a contract discovered through `slot` of `parent` */
function refName(parentName, slot) {
  if (slot === EIP1967_IMPL_SLOT) return `${parentName}_Implementation`;
  const index = BigInt(slot);
  return index < 1024n
    ? `${parentName}_Ref@slot${index}`
    : `${parentName}_Ref@${slot.slice(0, 10)}`;
}

/**
 * Walk out from the named contracts to everything they reach through storage.
 * Returns a Map of lowercase address -> name, manifest entries first.
 */
export function collectAccounts(stateAccounts, contractEntries, log = () => {}) {
  const found = new Map();
  const queue = [];

  for (const [name, address] of contractEntries) {
    const addr = normalizeAddr(address);
    if (found.has(addr)) continue;
    found.set(addr, name);
    queue.push(addr);
  }

  while (queue.length > 0) {
    const addr = queue.shift();
    const acct = stateAccounts[addr];
    if (!acct) continue;

    for (const { address, slot } of referencedContracts(acct, stateAccounts)) {
      if (found.has(address)) continue;
      const name = refName(found.get(addr), slot);
      found.set(address, name);
      queue.push(address);
      log(`  Discovered ${name}: ${address}`);
    }
  }

  return found;
}

/**
 * Accounts whose implementation pointer targets something the genesis does not carry.
 *
 * A different predicate from the one that built the account set: referencedContracts only
 * follows a pointer whose target already has code, so an implementation that failed to
 * deploy is dropped silently and nothing downstream notices.
 *
 * Checks the EIP-1967 slot on every account, and slot 1 on the beacons named in `beacons`.
 * Beacons need naming because slot 1 holds an ordinary field on anything else, and a
 * pointer-shaped word there is usually an EOA — an owner or an operator — which is not a
 * missing implementation. The original previewnet failure was a beacon, so covering only
 * EIP-1967 would leave exactly that case unguarded.
 */
export function findMissingImplementations(accounts, beacons = new Set()) {
  const present = new Set(accounts.map((a) => normalizeAddr(a.address)));
  const broken = [];
  for (const acct of accounts) {
    const address = normalizeAddr(acct.address);
    const slots = beacons.has(address)
      ? [EIP1967_IMPL_SLOT, BEACON_IMPL_SLOT]
      : [EIP1967_IMPL_SLOT];
    for (const slot of slots) {
      const word = acct.storage?.[slot];
      if (!word) continue;
      const impl = addressFromWord(word);
      if (!impl || present.has(impl)) continue;
      broken.push({ proxy: address, impl });
    }
  }
  return broken;
}

/**
 * Build the pallet-revive genesis accounts from an anvil state dump.
 * `deployments` is the dotns manifest: a flat `{ name: address }` map.
 */
export function buildGenesis(stateData, deployments, log = () => {}, tld) {
  // dotns multi-stage deploy writes a flat `{ name: addr, _seed: 0x0 }` manifest
  // (single-shot DotnsDeployer used to nest under `.contracts`). Underscore-prefixed
  // keys are metadata, not contracts: `_seed` from BaseDeployer's vm.serializeAddress,
  // and `_deployedFrom` once dotns-releases#12 lands. Filtering the prefix rather than
  // the one known name keeps this working when the next one is added.
  const contractEntries = Object.entries(deployments).filter(
    ([name]) => !name.startsWith("_")
  );
  const stateAccounts = stateData.accounts;

  log(`Found ${contractEntries.length} deployed contracts in the manifest`);
  log(`State dump contains ${Object.keys(stateAccounts).length} accounts`);

  const accountsToExtract = collectAccounts(stateAccounts, contractEntries, log);

  log(
    `Total accounts to extract: ${accountsToExtract.size} (${contractEntries.length} named + ${accountsToExtract.size - contractEntries.length} reachable through storage)`
  );
  log("");

  // Extract code + storage for every account
  const genesisAccounts = [];

  // A contract the manifest names is load-bearing: shipping a genesis without it
  // produces a chain that looks correctly configured and reverts at the first call.
  // Anything reached transitively is already known to carry code (referencedContracts
  // filters on it), so only these can legitimately be absent — and must not be.
  const namedAddresses = new Set(
    contractEntries.map(([, address]) => normalizeAddr(address))
  );

  for (const [address, name] of accountsToExtract) {
    const acct = stateAccounts[address];
    if (!acct) {
      if (namedAddresses.has(address)) {
        throw new Error(
          `${name} @ ${address} is named in the manifest but absent from the state dump. ` +
            `The deploy did not produce it, or the dump is from a different run.`
        );
      }
      log(`  ${name} @ ${address} ... not in state dump, skipping`);
      continue;
    }

    const hasCode = acct.code && acct.code !== "0x";
    const storage = {};

    if (acct.storage) {
      for (const [slot, value] of Object.entries(acct.storage)) {
        storage[padHex(slot, 32)] = padHex(value, 32);
      }
    }

    const slotCount = Object.keys(storage).length;
    log(
      `  ${name} @ ${address} ... ${hasCode ? "contract" : "EOA"}, ${slotCount} storage slots`
    );

    if (!hasCode) {
      if (namedAddresses.has(address)) {
        throw new Error(
          `${name} @ ${address} is named in the manifest but carries no code in the ` +
            `state dump. Its deploy stage did not run, or it reverted.`
        );
      }
      log(`    no code at ${address}, skipping`);
      continue;
    }

    // pallet-revive genesis Account format
    // contract_data is #[serde(flatten)] so code/storage are top-level fields
    // balance is sp_core::U256, whose serde impl comes from impl_serde and is HEX
    // ("0x0"). A decimal string here is not rejected, it is reinterpreted as hex,
    // so a balance of 16 would silently become 22.
    genesisAccounts.push({
      address,
      balance: "0x" + BigInt(acct.balance).toString(16),
      nonce: acct.nonce,
      code: acct.code,
      storage,
    });
  }

  // Beacons are recognised by manifest name; both real ones end in "Beacon".
  const beacons = new Set(
    contractEntries
      .filter(([name]) => name.endsWith("Beacon"))
      .map(([, address]) => normalizeAddr(address))
  );
  const brokenProxies = findMissingImplementations(genesisAccounts, beacons);
  if (brokenProxies.length > 0) {
    const detail = brokenProxies
      .map((b) => `  ${b.proxy} -> implementation ${b.impl} is not in the genesis`)
      .join("\n");
    throw new Error(
      `Genesis would ship ${brokenProxies.length} proxy/proxies with no implementation:\n` +
        `${detail}\nEvery call through such a proxy reverts on the live chain.`
    );
  }

  // The manifest is what consumers resolve against, so assert the output covers all of it.
  // Holds by construction today, since the loop throws on anything named it cannot extract —
  // checked anyway because it is the guarantee the artifact is judged on.
  const extracted = new Set(genesisAccounts.map((a) => normalizeAddr(a.address)));
  const missing = contractEntries
    .filter(([, address]) => !extracted.has(normalizeAddr(address)))
    .map(([name, address]) => `  ${name} @ ${normalizeAddr(address)}`);
  if (missing.length > 0) {
    throw new Error(
      `Genesis is missing ${missing.length} contract(s) named in the manifest:\n` +
        missing.join("\n")
    );
  }

  // The TLD is in the filename as documentation; it is in here so a consumer can assert it.
  // A rename defeats a filename, and the registry this genesis carries only suits one TLD.
  return tld ? { tld, accounts: genesisAccounts } : { accounts: genesisAccounts };
}

// CLI

function getArg(args, name) {
  const idx = args.indexOf(`--${name}`);
  if (idx === -1 || idx + 1 >= args.length) {
    console.error(`Missing required argument: --${name}`);
    process.exit(1);
  }
  return args[idx + 1];
}

function main() {
  const args = process.argv.slice(2);
  const statePath = getArg(args, "state");
  const deploymentsPath = getArg(args, "deployments");
  const outputPath = getArg(args, "output");
  const tld = getArg(args, "tld");

  const stateData = JSON.parse(readFileSync(statePath, "utf8"));
  const deployments = JSON.parse(readFileSync(deploymentsPath, "utf8"));

  console.log(`Reading manifest ${deploymentsPath}`);
  const genesisConfig = buildGenesis(
    stateData,
    deployments,
    (msg) => console.log(msg),
    tld
  );

  writeFileSync(outputPath, JSON.stringify(genesisConfig, null, 2));
  console.log(
    `\nWritten ${genesisConfig.accounts.length} genesis accounts to ${outputPath}`
  );
}

const invokedDirectly =
  process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  main();
}
