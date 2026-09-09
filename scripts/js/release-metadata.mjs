// Address and manifest metadata for a release.
//
//   build     --tag <TAG> [--out <dir>]                 write the two release files
//   validate                                            check the committed manifests, no build needed
//   changelog --current <file> [--previous <file>]       release-note lines about address changes
//             [--previous-tag <name>]
//   verify    --network <folder> --rpc <url>             check a committed manifest against a chain
//
// `build` and `changelog` run in both publish workflows; `validate` runs on pull requests, so a
// broken manifest fails there rather than at release time. `verify` stays out of the release
// path, which must work without reaching a chain. No dependencies: `cast` does the chain reads.

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const CONTRACT_LIST = join(ROOT, ".github", "abi-contracts.txt");
const CONSTANTS_SOL = join(ROOT, "contracts", "utils", "DotnsConstants.sol");

// Deployed by the StoreFactory constructor, so no registry key points at them.
const UNVERIFIABLE = ["LabelStoreBeacon", "UserStoreBeacon"];

// The registry is what a consumer bootstraps from; the factory is what every other address
// derives from. A manifest without them is not publishable.
const REQUIRED_LABELS = ["DotnsProtocolRegistry", "Create3Factory"];

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

function fail(message) {
  console.error(`[release-metadata] ${message}`);
  process.exit(1);
}

function log(message) {
  console.log(`[release-metadata] ${message}`);
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 2) {
    const flag = argv[i];
    if (!flag.startsWith("--")) fail(`expected a --flag, got '${flag}'`);
    const value = argv[i + 1];
    if (value === undefined) fail(`${flag} needs a value`);
    args[flag.slice(2)] = value;
  }
  return args;
}

// The carriage return matters: a list saved with CRLF endings would otherwise put "\r"
// inside an artefact path.
function readContractNames() {
  const names = readFileSync(CONTRACT_LIST, "utf8")
    .split("\n")
    .map((line) => line.replace(/\r$/, "").trim())
    .filter((line) => line !== "" && !line.startsWith("#"));
  if (names.length === 0) fail(`${CONTRACT_LIST} lists no contracts`);
  return names;
}

// forge emits an empty `bytecode.object` for interfaces and abstract bases, so the split
// comes from the build rather than a second hand-maintained list.
function classifyContracts(names) {
  const contracts = [];
  const abiOnly = [];
  const files = {};
  for (const name of names) {
    const artefact = join(ROOT, "out", `${name}.sol`, `${name}.json`);
    if (!existsSync(artefact)) {
      fail(`${artefact} not found; run forge build, or check .github/abi-contracts.txt`);
    }
    const bytecode = JSON.parse(readFileSync(artefact, "utf8"))?.bytecode?.object ?? "0x";
    (bytecode.length > 2 ? contracts : abiOnly).push(name);
    files[name] = `abis/${name}.json`;
  }
  return { contracts, abiOnly, files };
}

// Tracked files only, so a local `deploy:anvil` left in the working tree cannot reach a
// release.
function committedManifests() {
  let tracked;
  try {
    tracked = execFileSync("git", ["ls-files", "deployments"], { cwd: ROOT, encoding: "utf8" });
  } catch (err) {
    fail(`could not list tracked manifests: ${err.message}`);
  }
  const manifests = new Map();
  for (const path of tracked.split("\n")) {
    const match = path.match(/^deployments\/([^/]+)\/(\d+)\.json$/);
    if (!match) continue;
    const [, network, chainId] = match;
    if (manifests.has(network)) {
      fail(`${network} has more than one manifest; a network must have one chain id`);
    }
    manifests.set(network, { chainId: Number(chainId), path: join(ROOT, path) });
  }
  if (manifests.size === 0) fail("no committed deployment manifests found under deployments/");
  return manifests;
}

// `_seed` and any future bookkeeping key are pipeline state, not addresses.
function contractsFromManifest(path) {
  const parsed = JSON.parse(readFileSync(path, "utf8"));
  const contracts = {};
  const seen = new Map();
  for (const [label, address] of Object.entries(parsed)) {
    if (label.startsWith("_")) continue;
    if (typeof address !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(address)) {
      fail(`${path}: ${label} is not an address`);
    }
    const key = address.toLowerCase();
    if (seen.has(key)) {
      fail(`${path}: ${label} and ${seen.get(key)} share the address ${address}`);
    }
    seen.set(key, label);
    contracts[label] = address;
  }
  for (const label of REQUIRED_LABELS) {
    if (!contracts[label]) fail(`${path}: missing ${label}`);
  }
  return contracts;
}

function writeJson(path, value) {
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
}

// `--addresses false` omits deployments.json. A pre-release is cut to be deployed, so the
// addresses on record still belong to the previous deployment of different code; shipping them
// under this tag would break the promise that a release's addresses and ABIs came from the same
// release. release-manifest.json describes this release's own contents, so it is always written.
function build(args) {
  const tag = args.tag;
  if (!tag) fail("build needs --tag");
  const withAddresses = args.addresses !== "false";
  const outDir = args.out ? resolve(process.cwd(), args.out) : join(ROOT, "release");
  mkdirSync(outDir, { recursive: true });

  if (withAddresses) {
    const networks = {};
    for (const [network, { chainId, path }] of committedManifests()) {
      networks[network] = { chainId, contracts: contractsFromManifest(path) };
    }
    writeJson(join(outDir, "deployments.json"), { version: tag, networks });
    const names = Object.keys(networks);
    log(`${tag}: ${names.length} network(s): ${names.join(", ")}`);
  } else {
    log(`${tag}: no addresses, this release is not deployed yet`);
  }

  const { contracts, abiOnly, files } = classifyContracts(readContractNames());
  writeJson(join(outDir, "release-manifest.json"), { version: tag, contracts, abiOnly, files });
  log(`${contracts.length} contracts, ${abiOnly.length} ABI-only entries`);
}

// Everything build checks about the manifests, without needing `out/`, so a pull request can
// run it. Contract names are checked against sources rather than artefacts for the same reason.
function validate() {
  const manifests = committedManifests();
  for (const [network, { chainId, path }] of manifests) {
    const contracts = contractsFromManifest(path);
    log(`${network} (chain ${chainId}): ${Object.keys(contracts).length} addresses`);
  }
  const names = readContractNames();
  const sources = trackedSourceNames();
  const missing = names.filter(
    (name) => !sources.has(name) && !existsSync(join(ROOT, "out", `${name}.sol`, `${name}.json`)),
  );
  if (missing.length > 0) {
    fail(`no source or build artefact for: ${missing.join(", ")}`);
  }
  log(`${manifests.size} manifest(s) and ${names.length} listed contracts are valid`);
}

function trackedSourceNames() {
  let tracked;
  try {
    tracked = execFileSync("git", ["ls-files", "contracts"], { cwd: ROOT, encoding: "utf8" });
  } catch (err) {
    fail(`could not list tracked sources: ${err.message}`);
  }
  return new Set(
    tracked
      .split("\n")
      .filter((path) => path.endsWith(".sol"))
      .map((path) => basename(path, ".sol")),
  );
}

// Compared per address rather than by serialising, so a manifest whose keys were reordered, or
// whose checksum casing differs, is not announced as a move that did not happen.
function sameAddresses(before = {}, after = {}) {
  const labels = new Set([...Object.keys(before), ...Object.keys(after)]);
  for (const label of labels) {
    if ((before[label] ?? "").toLowerCase() !== (after[label] ?? "").toLowerCase()) return false;
  }
  return true;
}

function readDeployments(path) {
  const parsed = JSON.parse(readFileSync(path, "utf8"));
  return parsed?.networks ?? {};
}

// Emitted into the release body so a moved address set is announced rather than left for a
// consumer to diff. Kept here rather than in the workflows so the two cannot drift.
function changelog(args) {
  if (!args.current) fail("changelog needs --current");
  const current = readDeployments(args.current);
  if (!args.previous) {
    console.log("\nNo earlier release carries `deployments.json`, so there is nothing to compare against.");
    return;
  }
  const previous = readDeployments(args.previous);
  const previousTag = args["previous-tag"] ?? "the previous release";
  const changed = Object.keys(current).filter(
    (name) => previous[name] && !sameAddresses(previous[name].contracts, current[name].contracts),
  );
  const added = Object.keys(current).filter((name) => !previous[name]);
  const removed = Object.keys(previous).filter((name) => !current[name]);

  console.log("");
  if (changed.length > 0) {
    console.log(
      `Addresses changed since ${previousTag} on: ${changed.join(", ")}. Update any pinned copy before upgrading.`,
    );
  } else {
    console.log(`Addresses are unchanged since ${previousTag}.`);
  }
  if (added.length > 0) console.log(`Networks added since ${previousTag}: ${added.join(", ")}.`);
  if (removed.length > 0) {
    console.log(`Networks no longer published since ${previousTag}: ${removed.join(", ")}.`);
  }
}

// Read from the library that declares them, so adding a contract needs no edit here.
// PERSONHOOD_CONTEXT is an application identifier that shares the bytes32 shape.
function registryKeys() {
  const source = readFileSync(CONSTANTS_SOL, "utf8");
  const keys = [];
  const pattern = /bytes32 internal constant (\w+) = bytes32\("([^"]+)"\)/g;
  for (const [, name, key] of source.matchAll(pattern)) {
    if (name !== "PERSONHOOD_CONTEXT") keys.push(key);
  }
  if (keys.length === 0) fail(`no registry keys found in ${CONSTANTS_SOL}`);
  return keys;
}

function cast(args) {
  try {
    return execFileSync("cast", args, { encoding: "utf8", cwd: tmpdir() }).trim();
  } catch (err) {
    const detail = (err.stderr || err.message || "").toString().trim().split("\n")[0];
    fail(`cast ${args[0]} failed: ${detail}`);
  }
}

// Solidity's bytes32("registrar"): the ASCII bytes, left aligned and right padded.
function bytes32FromString(value) {
  const hex = Buffer.from(value, "ascii").toString("hex");
  if (hex.length > 64) fail(`registry key '${value}' does not fit in bytes32`);
  return `0x${hex.padEnd(64, "0")}`;
}

// Which key holds which contract is asserted at deploy time by
// `WireDeployments._verifyDeployment`. This checks what deploy time cannot: that the manifest
// and the chain still agree afterwards, which a set comparison answers without repeating the
// pairing.
function verify(args) {
  const { network, rpc } = args;
  if (!network || !rpc) fail("verify needs --network and --rpc");

  const manifests = committedManifests();
  const entry = manifests.get(network);
  if (!entry) {
    fail(`no committed manifest for '${network}'; have: ${[...manifests.keys()].join(", ")}`);
  }
  const contracts = contractsFromManifest(entry.path);
  const byAddress = new Map(
    Object.entries(contracts).map(([label, address]) => [address.toLowerCase(), label]),
  );

  // Checked before anything else so pointing at the wrong endpoint says so, rather than
  // surfacing as a registry with no code.
  const chainId = Number(cast(["chain-id", "--rpc-url", rpc]));
  if (chainId !== entry.chainId) {
    fail(`${network} is chain ${entry.chainId}, but this endpoint is chain ${chainId}`);
  }

  const registry = contracts.DotnsProtocolRegistry;
  if (cast(["code", registry, "--rpc-url", rpc]) === "0x") {
    fail(`${registry} has no code on this chain; wrong network or wrong registry address`);
  }
  log(`verifying ${network} (chain ${entry.chainId}) via ${registry}`);

  const problems = [];
  const resolved = new Set();
  for (const key of registryKeys()) {
    const address = cast([
      "call",
      registry,
      "get(bytes32)(address)",
      bytes32FromString(key),
      "--rpc-url",
      rpc,
    ]);
    if (address === ZERO_ADDRESS) {
      problems.push(`key '${key}' is unset on chain`);
      continue;
    }
    const label = byAddress.get(address.toLowerCase());
    if (!label) {
      problems.push(`key '${key}' resolves to ${address}, which is not in the manifest`);
      continue;
    }
    if (cast(["code", address, "--rpc-url", rpc]) === "0x") {
      problems.push(`key '${key}' resolves to ${address} (${label}), which has no code`);
      continue;
    }
    resolved.add(address.toLowerCase());
    console.log(`  ok   ${key} ${address} ${label}`);
  }

  // The registry is the seed rather than one of its own entries, and nothing points at the
  // beacons.
  const unpointed = [registry, ...UNVERIFIABLE.map((label) => contracts[label])]
    .filter(Boolean)
    .map((address) => address.toLowerCase());
  const notExpected = new Set(unpointed);
  for (const [address, label] of byAddress) {
    if (!resolved.has(address) && !notExpected.has(address)) {
      problems.push(`${label} ${contracts[label]} is in the manifest but no key points at it`);
    }
  }


  for (const label of UNVERIFIABLE) {
    if (contracts[label]) {
      console.log(`  skip ${label} ${contracts[label]} (constructor-deployed)`);
    }
  }

  if (problems.length > 0) {
    console.error(`[release-metadata] ${problems.length} problem(s) on ${network}:`);
    for (const line of problems) console.error(`  ${line}`);
    fail("the committed manifest does not describe this chain");
  }
  log(`${network} matches the chain`);
}

const [mode, ...rest] = process.argv.slice(2);
const args = parseArgs(rest);
if (mode === "build") build(args);
else if (mode === "validate") validate();
else if (mode === "changelog") changelog(args);
else if (mode === "verify") verify(args);
else {
  fail(
    "usage: release-metadata.mjs build --tag <TAG> [--out <dir>] | validate | " +
      "changelog --current <file> [--previous <file>] [--previous-tag <name>] | " +
      "verify --network <folder> --rpc <url>",
  );
}
