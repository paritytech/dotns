// Address and manifest metadata for a release.
//
//   build      --tag <TAG> [--out <dir>]                 write the release files
//   validate                                             check the committed manifests, no build needed
//   changelog  --current <file> [--previous <file>]      release-note lines about address changes
//              [--previous-tag <name>]
//   changedset --previous <codehashes.json>              contracts whose built code differs, one per line
//   bases      --out <file>                              published ABIs each contract inherits from
//   abidiff    --current <dir> [--previous <dir>]        selector-level ABI diff for the release body
//              [--previous-tag <name>] [--json <file>]
//              [--bases <file>]
//   verify     --network <folder> --rpc <url> [--tag <TAG>]  check a committed manifest against a chain
//
// `build`, `bases` and `abidiff` run in both publish workflows, and `changelog` in the release
// one. `validate` runs on pull requests, so a broken manifest fails there rather than at release
// time. `verify` stays out of the release
// path, which must work without reaching a chain; with `--tag` it also checks the chain's
// declared protocol version and code identity. `changedset` names exactly what a release
// changed, for upgrade tooling (which lives outside this repository) and for humans. No
// dependencies: `cast` does the chain reads and the hashing.

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const CONTRACT_LIST = join(ROOT, ".github", "abi-contracts.txt");
const CONSTANTS_SOL = join(ROOT, "contracts", "utils", "DotnsConstants.sol");

// Deployed by the StoreFactory initialiser, so no registry key points at them.
const UNVERIFIABLE = ["LabelStoreBeacon", "UserStoreBeacon"];

// Keys the forward check tolerates as unset. Multicall3 is deliberately never registered:
// registry membership is a trust signal other contracts read, and a generic call forwarder
// must not carry it (see WireDeployments). protocolRegistry is the registry registering
// itself so its implementation has a declared codehash; networks deployed before that key
// existed leave it unset.
const UNSET_TOLERATED = {
  multicall3: "deliberately never registered",
  protocolRegistry: "not registered on this network (predates self-registration)",
};

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

// Solc appends a CBOR metadata blob to the runtime bytecode; its byte length sits in the last
// two bytes. Stripped before hashing so a comment-only edit, which changes only the metadata's
// embedded source hash, does not read as a code change. The plausibility checks fail loudly
// rather than mis-strip: a blob longer than the code, or one that does not start with a CBOR
// map marker (0xa1/0xa2), means the layout assumption broke with a compiler change.
function stripCborMetadata(name, hex) {
  const code = hex.startsWith("0x") ? hex.slice(2) : hex;
  if (code.length < 4) fail(`${name}: runtime bytecode too short to carry metadata`);
  const blobLength = parseInt(code.slice(-4), 16);
  const stripped = code.length / 2 - blobLength - 2;
  if (!Number.isInteger(stripped) || stripped <= 0) {
    fail(`${name}: implausible CBOR metadata length ${blobLength}`);
  }
  const marker = code.slice(stripped * 2, stripped * 2 + 2);
  if (marker !== "a1" && marker !== "a2") {
    fail(`${name}: expected a CBOR map marker before the metadata blob, found 0x${marker}`);
  }
  return `0x${code.slice(0, stripped * 2)}`;
}

// The metadata at the end is not the only metadata in the code. A contract that deploys other
// contracts (with `new`, for example) carries a copy of their creation code, and each copy ends
// with that contract's own metadata. StoreFactory is an example: it contains LabelStore's
// creation code, so a comment-only edit to LabelStore changes a few bytes inside StoreFactory.
//
// To ignore that, the hash (digest) inside each embedded metadata block is set to zeros. The
// code keeps its length, so nothing else moves, and the compiler version bytes are kept. A real
// change to an embedded contract's code, or to the compiler, still changes the hash.
//
// A block is found by its exact shape, not by where it sits: {"ipfs": <34-byte hash>, "solc":
// <3-byte version>} followed by its length, 0x0033. That is what solc writes with foundry's
// default `bytecode_hash = "ipfs"`. The older `bzzr1` shape is handled too. With
// `bytecode_hash = "none"` there is no hash to clear. Normal code does not contain these exact
// bytes by chance, and a match only counts if it starts on a whole byte.
const EMBEDDED_METADATA_SHAPES = [
  { prefix: "a264697066735822", digestHexLength: 68, suffix: "0033" },
  { prefix: "a265627a7a72315820", digestHexLength: 64, suffix: "0032" },
];

function zeroEmbeddedMetadataDigests(hex) {
  let code = hex.toLowerCase();
  for (const { prefix, digestHexLength, suffix } of EMBEDDED_METADATA_SHAPES) {
    const shape = new RegExp(
      `${prefix}[0-9a-f]{${digestHexLength}}64736f6c6343[0-9a-f]{6}${suffix}`,
      "g",
    );
    const zeros = "0".repeat(digestHexLength);
    let match;
    while ((match = shape.exec(code)) !== null) {
      // `code` starts with "0x", so every byte starts at an even index. A match at an odd index
      // starts in the middle of a byte, so it is not a real block. Keep searching from the next
      // character.
      if (match.index % 2 !== 0) {
        shape.lastIndex = match.index + 1;
        continue;
      }
      const digestStart = match.index + prefix.length;
      code = code.slice(0, digestStart) + zeros + code.slice(digestStart + digestHexLength);
    }
  }
  return code;
}

// keccak256 via `cast keccak`, keeping the script dependency-free like the chain reads.
function keccakHex(hex) {
  return cast(["keccak", hex]);
}

// Saved in codehashes.json as `hashScheme`, so that `changedset` can hash the current build the
// same way the previous file was hashed. Comparing hashes made in two different ways would show
// changes that are not there.
//   1: the metadata at the end is removed. Files written before `hashScheme` existed use this.
//   2: the same, and the hashes inside embedded metadata are set to zeros as well.
// Both give the same result for a contract that does not deploy other contracts.
const HASH_SCHEME = 2;
const HASH_SCHEMES = [1, 2];

// Stripped-metadata hash of each deployable contract's built runtime bytecode. These are
// artifact-side hashes for comparing builds with builds (the changed-set); they are never
// compared against on-chain hashes, which live in a different domain (see `verify`).
function builtCodehashes(scheme = HASH_SCHEME) {
  const { contracts } = classifyContracts(readContractNames());
  const hashes = {};
  for (const name of contracts) {
    const artefact = JSON.parse(
      readFileSync(join(ROOT, "out", `${name}.sol`, `${name}.json`), "utf8"),
    );
    const runtime = artefact?.deployedBytecode?.object;
    if (!runtime || runtime === "0x") fail(`${name}: no deployed bytecode in the artefact`);
    const stripped = stripCborMetadata(name, runtime);
    hashes[name] = keccakHex(scheme >= 2 ? zeroEmbeddedMetadataDigests(stripped) : stripped);
  }
  return hashes;
}

// The inputs that make an artifact hash interpretable: the same source built by a different
// toolchain hashes differently, and that difference is a real code change on chain.
function buildInputs() {
  const [firstName] = classifyContracts(readContractNames()).contracts;
  const metadata = JSON.parse(
    readFileSync(join(ROOT, "out", `${firstName}.sol`, `${firstName}.json`), "utf8"),
  )?.metadata;
  const lockPath = join(ROOT, "foundry.lock");
  return {
    solcVersion: metadata?.compiler?.version ?? null,
    optimizer: metadata?.settings?.optimizer ?? null,
    viaIr: metadata?.settings?.viaIR ?? null,
    evmVersion: metadata?.settings?.evmVersion ?? null,
    foundryLockSha256: existsSync(lockPath)
      ? createHash("sha256").update(readFileSync(lockPath)).digest("hex")
      : null,
  };
}

// Contracts whose built code differs from a previous release's codehashes.json: the exact set
// a release changed. An upgrade must cover all of it before declaring the release on a network,
// or the declared protocol version would over-claim; the tooling that performs upgrades lives
// outside this repository and consumes this output.
function changedset(args) {
  if (!args.previous) fail("changedset needs --previous <codehashes.json>");
  const previous = JSON.parse(readFileSync(resolve(process.cwd(), args.previous), "utf8"));
  const previousHashes = previous?.hashes;
  if (!previousHashes) fail(`${args.previous} has no 'hashes' map`);
  // Hash the build the same way the previous file was hashed. Otherwise a change in how the
  // hash is computed would look like a change in the code.
  const scheme = previous.hashScheme ?? 1;
  if (!HASH_SCHEMES.includes(scheme)) {
    fail(
      `${args.previous} uses hashScheme ${scheme}; this script knows ${HASH_SCHEMES.join(", ")}`,
    );
  }
  if (scheme < HASH_SCHEME) {
    // Printed to stderr, because stdout is the list that upgrade tooling reads.
    console.error(
      `[release-metadata] ${args.previous} uses hashScheme ${scheme}, so this build is hashed ` +
        `the same way. A contract that deploys other contracts with \`new\` is listed if any ` +
        `contract it deploys changed at all, even if only a comment changed.`,
    );
  }
  const current = builtCodehashes(scheme);
  // Union, not just the current set: a contract only in the previous release was removed and a
  // contract only in this one is new. Neither is coverable by an in-place upgrade, so both must
  // surface and force the coverage gate to refuse rather than dropping out of the diff.
  const names = new Set([...Object.keys(current), ...Object.keys(previousHashes)]);
  for (const name of [...names].sort()) {
    if ((previousHashes[name] ?? "").toLowerCase() !== (current[name] ?? "").toLowerCase()) {
      console.log(name);
    }
  }
}

// Canonical signature text for one ABI entry, tuples expanded recursively, so two entries have
// the same signature exactly when they have the same selector (or topic0): the signature string
// is the full selector identity, with nothing to hash.
function canonicalType(param) {
  if (param.type.startsWith("tuple")) {
    const inner = `(${(param.components ?? []).map(canonicalType).join(",")})`;
    return inner + param.type.slice("tuple".length);
  }
  return param.type;
}

function signatureOf(entry) {
  return `${entry.name}(${(entry.inputs ?? []).map(canonicalType).join(",")})`;
}

// name -> Set of signatures, per ABI kind. Overloads land in one set under their shared name.
function signaturesByKind(abi) {
  const kinds = { function: new Map(), event: new Map(), error: new Map() };
  for (const entry of abi) {
    // `Object.hasOwn` rather than a truthiness check: an ABI `constructor` entry would
    // otherwise look up the object's own prototype property of that name.
    if (!Object.hasOwn(kinds, entry.type)) continue;
    const kind = kinds[entry.type];
    if (!kind.has(entry.name)) kind.set(entry.name, new Set());
    kind.get(entry.name).add(signatureOf(entry));
  }
  return kinds;
}

// Reads what the directory actually holds rather than what the current contract list names:
// the previous release can carry contracts this release no longer publishes, and those must
// surface as removals instead of silently dropping out of the diff.
function readAbiDir(dir) {
  const abis = new Map();
  for (const file of readdirSync(dir)) {
    if (!file.endsWith(".json")) continue;
    abis.set(basename(file, ".json"), JSON.parse(readFileSync(join(dir, file), "utf8")));
  }
  return abis;
}

// Selector-level diff of one contract's ABI. A struct gaining a field is the case that
// motivated this: same function name, different selector, an old caller gets a bare revert. So
// "changed" (same name, different signature set) is the highest-severity class and is reported
// before pure additions and removals.
function diffAbi(previous, current) {
  const before = signaturesByKind(previous);
  const after = signaturesByKind(current);
  const result = {};
  for (const kind of ["function", "event", "error"]) {
    const names = new Set([...before[kind].keys(), ...after[kind].keys()]);
    const added = [];
    const removed = [];
    const changed = [];
    for (const name of names) {
      const old = before[kind].get(name);
      const now = after[kind].get(name);
      if (old && now) {
        const oldOnly = [...old].filter((s) => !now.has(s)).sort();
        const nowOnly = [...now].filter((s) => !old.has(s)).sort();
        // Differing on both sides is a moved selector, the bare-revert case the changed banner
        // warns about. A one-sided difference is an overload added or removed: the remaining
        // selectors still exist, so callers of them are unaffected and the entry belongs with
        // the additions or removals instead.
        if (oldOnly.length > 0 && nowOnly.length > 0) {
          changed.push({ name, was: oldOnly, now: nowOnly });
        } else {
          added.push(...nowOnly);
          removed.push(...oldOnly);
        }
      } else if (now) {
        added.push(...now);
      } else {
        removed.push(...old);
      }
    }
    if (added.length + removed.length + changed.length > 0) {
      result[kind] = {
        changed: changed.sort((a, b) => a.name.localeCompare(b.name)),
        added: added.sort(),
        removed: removed.sort(),
      };
    }
  }
  return result;
}

// For each published ABI, the other published ABIs it inherits from, nearest first. This comes
// from the build itself, not from names, so a contract is matched with its interface whatever
// they are called. For example, DotnsFlatPricing implements IDotnsPricing. Bases that are not
// published ABIs are skipped, because the release body can only point at ABIs that ship in the
// release.
//
// A contract's artifact lists its bases as AST ids. Ids only mean something inside the compiler
// run that made them, and an incremental `forge build` can leave artifacts from several runs in
// out/. So each artifact is matched to the build info of its own run (foundry.toml keeps
// `build_info = true`), and its base ids are turned into names there.
function publishedBases() {
  const buildInfoDir = join(ROOT, "out", "build-info");
  if (!existsSync(buildInfoDir)) {
    fail(`${buildInfoDir} not found; foundry.toml needs \`build_info = true\`, then forge build`);
  }
  // For each compiler run: contract id -> { name, path }.
  const runs = readdirSync(buildInfoDir)
    .filter((file) => file.endsWith(".json"))
    .map((file) => {
      const info = JSON.parse(readFileSync(join(buildInfoDir, file), "utf8"));
      const byId = new Map();
      for (const [path, source] of Object.entries(info?.output?.sources ?? {})) {
        for (const node of source?.ast?.nodes ?? []) {
          if (node.nodeType === "ContractDefinition") byId.set(node.id, { name: node.name, path });
        }
      }
      return byId;
    });

  const published = readContractNames();
  const publishedSet = new Set(published);
  const bases = {};
  for (const name of published) {
    const path = join(ROOT, "out", `${name}.sol`, `${name}.json`);
    if (!existsSync(path)) {
      fail(`${path} not found; run forge build, or check .github/abi-contracts.txt`);
    }
    const artefact = JSON.parse(readFileSync(path, "utf8"));
    const def = artefact?.ast?.nodes?.find(
      (node) => node.nodeType === "ContractDefinition" && node.name === name,
    );
    if (!def) fail(`${path} has no AST for ${name}; foundry.toml needs \`ast = true\``);
    // The run that built this artifact is the one that has this contract, in this file, under
    // the same id.
    const run = runs.find((byId) => {
      const known = byId.get(def.id);
      return known?.name === name && known.path === artefact.ast.absolutePath;
    });
    if (!run) {
      fail(`no build info in out/build-info matches ${name}; run forge clean && forge build`);
    }
    // The first id is the contract itself.
    const found = (def.linearizedBaseContracts ?? [])
      .slice(1)
      .map((id) => run.get(id)?.name)
      .filter((base) => base && publishedSet.has(base));
    if (found.length > 0) bases[name] = found;
  }
  return bases;
}

function writeBases(args) {
  if (!args.out) fail("bases needs --out <file>");
  const bases = publishedBases();
  writeJson(resolve(process.cwd(), args.out), bases);
  log(`${Object.keys(bases).length} published ABI(s) inherit from another published ABI`);
}

function readBases(path) {
  const bases = JSON.parse(readFileSync(resolve(process.cwd(), path), "utf8"));
  const valid =
    bases &&
    typeof bases === "object" &&
    !Array.isArray(bases) &&
    Object.values(bases).every((list) => Array.isArray(list));
  if (!valid) {
    fail(`${path} does not map contract names to lists of bases; write it with \`bases\``);
  }
  return bases;
}

// Order of the lines in the release body. Breaking changes are the ones that stop an existing
// caller or indexer from working. The rest are grouped after them.
const BREAKING_GROUPS = [
  "functionChanged",
  "functionRemoved",
  "contractRemoved",
  "eventChanged",
  "eventRemoved",
];
const OTHER_GROUPS = [
  "contractAdded",
  "functionAdded",
  "eventAdded",
  "errorChanged",
  "errorAdded",
  "errorRemoved",
];

// Writes the ABI part of the release body, plus the full diff as JSON.
//
// The body is kept short so that people read it. It lists only the breaking changes, one line
// each: changed function signatures, removed functions, contracts no longer published, then
// changed or removed events. Everything else (additions, new contracts, custom errors) goes in a
// collapsed block with a count. The JSON always has the full diff for every contract.
//
// A contract and the interfaces it implements usually publish the same functions and events, so
// one change would be listed several times. `--bases` (written by `bases`) says which published
// ABIs each contract inherits from. A contract's line is left out when one of those bases has
// exactly the same line, so the change is listed once, under the interface that declares it,
// which is what callers bind to. A change that only the contract has is still listed. Without
// `--bases`, every contract is listed on its own.
//
// When there is nothing to report, it says so, so an empty section is never mistaken for a
// missing one. A previous release without ABIs is reported the same way instead of failing.
function abidiff(args) {
  if (!args.current) fail("abidiff needs --current <dir>");
  const previousTag = args["previous-tag"] ?? "the previous release";
  const report = { previousTag: args["previous-tag"] ?? null, contracts: {} };
  const lines = [""];

  if (!args.previous) {
    lines.push("No earlier release carries ABIs to diff against.");
    report.previousUnavailable = true;
  } else {
    const currentAbis = readAbiDir(resolve(process.cwd(), args.current));
    const previousAbis = readAbiDir(resolve(process.cwd(), args.previous));
    const code = (text) => `\`${text}\``;
    const signatures = (list) => list.map(code).join(", ");
    const member = (signature) => signature.slice(0, signature.indexOf("("));

    // One entry per change. `change` describes the change without naming the contract, so a
    // contract's entry can be matched against its interface's.
    const entries = [];
    const add = (contract, group, change, text) => entries.push({ contract, group, change, text });

    for (const name of [...currentAbis.keys()].sort()) {
      const previousAbi = previousAbis.get(name);
      if (!previousAbi) {
        add(name, "contractAdded", "added", "new contract");
        report.contracts[name] = { newContract: true };
        continue;
      }
      const diff = diffAbi(previousAbi, currentAbis.get(name));
      if (Object.keys(diff).length === 0) continue;
      report.contracts[name] = diff;
      for (const [kind, { changed, added, removed }] of Object.entries(diff)) {
        // Functions need no label. Events and errors say what they are.
        const label = kind === "function" ? "" : ` ${kind}`;
        for (const entry of changed) {
          add(
            name,
            `${kind}Changed`,
            `${kind} ${entry.was.join(" ")} > ${entry.now.join(" ")}`,
            `${code(`${name}.${entry.name}`)}${label}: ` +
              `${signatures(entry.was)} → ${signatures(entry.now)}`,
          );
        }
        for (const signature of removed) {
          add(
            name,
            `${kind}Removed`,
            `${kind} removed ${signature}`,
            `${code(`${name}.${member(signature)}`)}${label}: ${code(signature)} removed`,
          );
        }
        for (const signature of added) {
          add(
            name,
            `${kind}Added`,
            `${kind} added ${signature}`,
            `${code(`${name}.${member(signature)}`)}${label}: ${code(signature)} added`,
          );
        }
      }
    }
    for (const name of [...previousAbis.keys()].sort()) {
      if (!currentAbis.has(name)) {
        add(name, "contractRemoved", "removed", "no longer published");
        report.contracts[name] = { removedContract: true };
      }
    }

    // Leave out a contract's line when one of its bases has the same one. A contract that is new
    // together with its bases is named on its base's line instead. That is the furthest base
    // that is also new, which has no new base of its own, so the whole family ends up on one
    // line. A removed contract is not in the current build, so its bases are not known and it
    // keeps its own line.
    const bases = args.bases ? readBases(args.bases) : {};
    const byChange = new Map(entries.map((entry) => [`${entry.contract} ${entry.change}`, entry]));
    const isContractLine = (entry) =>
      entry.group === "contractAdded" || entry.group === "contractRemoved";
    const shown = entries.filter((entry) => {
      const covering = (bases[entry.contract] ?? []).filter((base) =>
        byChange.has(`${base} ${entry.change}`),
      );
      if (covering.length === 0) return true;
      if (isContractLine(entry)) {
        const home = byChange.get(`${covering.at(-1)} ${entry.change}`);
        home.names = [...(home.names ?? [home.contract]), entry.contract];
      }
      return false;
    });
    const nameList = (names) => {
      const quoted = names.map(code);
      return quoted.length > 1
        ? `${quoted.slice(0, -1).join(", ")} and ${quoted.at(-1)}`
        : quoted[0];
    };
    const line = (entry) =>
      isContractLine(entry)
        ? `- ${nameList(entry.names ?? [entry.contract])}: ` +
          (entry.names && entry.group === "contractAdded" ? "new contracts" : entry.text)
        : `- ${entry.text}`;
    const inOrder = (groups) =>
      groups.flatMap((group) => shown.filter((entry) => entry.group === group)).map(line);
    const breaking = inOrder(BREAKING_GROUPS);
    const others = inOrder(OTHER_GROUPS);

    if (breaking.length + others.length === 0) {
      lines.push(`## ABI changes since ${previousTag}`, "", `No ABI changes since ${previousTag}.`);
    } else {
      lines.push(`## Breaking ABI changes since ${previousTag}`, "");
      lines.push(...(breaking.length > 0 ? breaking : ["None."]));
      if (others.length > 0) {
        lines.push(
          "",
          "<details>",
          `<summary>Other ABI changes (${others.length})</summary>`,
          "",
          ...others,
          "",
          "</details>",
        );
      }
    }
  }

  if (args.json) writeJson(resolve(process.cwd(), args.json), report);
  console.log(lines.join("\n"));
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

  // Code identity for this release's build. Written by pre-releases too: deploys run from
  // pre-release tags, and an upgrade diffs its build against the previous release's file.
  writeJson(join(outDir, "codehashes.json"), {
    version: tag,
    hashScheme: HASH_SCHEME,
    build: buildInputs(),
    hashes: builtCodehashes(),
  });
  log("codehashes.json written");
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

const ERC1967_IMPLEMENTATION_SLOT =
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const ZERO_HASH = `0x${"0".repeat(64)}`;

// Chain-side hash of the code that executes for `addr`: the ERC1967 implementation's for a
// proxy, its own otherwise. Hashed over `eth_getCode` bytes, the same domain the deploy scripts
// declared from (forge evaluates `.codehash` in simulation over RPC-fetched code), so this
// comparison never crosses into the artifact-hash domain of codehashes.json.
function executingCodehash(rpc, addr) {
  const slot = cast(["storage", addr, ERC1967_IMPLEMENTATION_SLOT, "--rpc-url", rpc]);
  const implementation = `0x${slot.slice(-40)}`;
  const target = /^0x0{40}$/.test(implementation) ? addr : implementation;
  return keccakHex(cast(["code", target, "--rpc-url", rpc]));
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

  // With --tag: the chain must declare exactly the release being checked. Bare semver on both
  // sides; a leading v on the flag is tolerated since tags carry one.
  const tag = args.tag ? args.tag.replace(/^v/, "") : null;
  if (tag) {
    const declaredVersion = cast([
      "call",
      registry,
      "protocolVersion()(string)",
      "--rpc-url",
      rpc,
    ]).replace(/^"|"$/g, "");
    if (declaredVersion === tag) {
      console.log(`  ok   protocolVersion ${declaredVersion}`);
    } else {
      problems.push(`chain declares protocol version '${declaredVersion}', expected '${tag}'`);
    }
  }

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
      // protocolRegistry's tolerance is transitional and lapses under --tag: passing a tag
      // asserts the network is post-declaration, so the self-key must exist there.
      const tolerated =
        Object.hasOwn(UNSET_TOLERATED, key) && !(tag && key === "protocolRegistry");
      if (tolerated) {
        console.log(`  skip ${key} (${UNSET_TOLERATED[key]})`);
        continue;
      }
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
    // With --tag: the declared code identity must match the code actually executing for the
    // key. Drift here is the out-of-band-upgrade signal the declarations exist for.
    if (tag) {
      const declared = cast([
        "call",
        registry,
        "expectedCodehash(bytes32)(bytes32)",
        bytes32FromString(key),
        "--rpc-url",
        rpc,
      ]);
      if (declared === ZERO_HASH) {
        // A key that is tolerated unset is also tolerated undeclared. Such keys are outside
        // the declared release surface, so the declaration pass never writes a codehash for
        // them; a network whose genesis predates the current policy can still have one set,
        // and that combination (set, no code identity) is expected there.
        if (UNSET_TOLERATED[key]) {
          resolved.add(address.toLowerCase());
          console.log(`  skip ${key} ${address} (${label}: no declaration, ${UNSET_TOLERATED[key]})`);
          continue;
        }
        problems.push(`key '${key}' (${label}) has no declared codehash`);
        continue;
      }
      const actual = executingCodehash(rpc, address);
      if (declared.toLowerCase() !== actual.toLowerCase()) {
        problems.push(
          `key '${key}' (${label}) declares ${declared} but the executing code hashes to ${actual}`,
        );
        continue;
      }
    }
    resolved.add(address.toLowerCase());
    console.log(`  ok   ${key} ${address} ${label}`);
  }

  // The registry registers itself these days (so its implementation has a declared codehash),
  // but networks deployed before that carry no such key, so it stays tolerated here as
  // unpointed. Nothing points at the beacons on any network.
  // Multicall3 is in the manifest for consumers but deliberately holds no registry key, and
  // pricing models are reached through DotnsCostModelRegistry rather than a key of their own,
  // so the reverse check must not read either as an orphan.
  const unpointed = [
    registry,
    contracts.Multicall3,
    contracts.DotnsFlatPricing,
    ...UNVERIFIABLE.map((label) => contracts[label]),
  ]
    .filter(Boolean)
    .map((address) => address.toLowerCase());
  const notExpected = new Set(unpointed);
  for (const [address, label] of byAddress) {
    if (!resolved.has(address) && !notExpected.has(address)) {
      // A `*Legacy` entry records an address that became stale or unused after an in-place
      // upgrade: when a contract moves to a new address, the outgoing one keeps its manifest
      // entry under the `Legacy` suffix instead of being erased, because live state can keep
      // depending on it after nothing points at it. Unkeyed by design, so the reverse check
      // skips it instead of reading it as an orphan.
      if (label.endsWith("Legacy")) {
        console.log(`  skip ${label} ${contracts[label]} (superseded deployment, kept for the beacon upgrade path)`);
        continue;
      }
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
else if (mode === "changedset") changedset(args);
else if (mode === "bases") writeBases(args);
else if (mode === "abidiff") abidiff(args);
else if (mode === "verify") verify(args);
else {
  fail(
    "usage: release-metadata.mjs build --tag <TAG> [--out <dir>] | validate | " +
      "changelog --current <file> [--previous <file>] [--previous-tag <name>] | " +
      "changedset --previous <codehashes.json> | " +
      "bases --out <file> | " +
      "abidiff --current <dir> [--previous <dir>] [--previous-tag <name>] [--json <file>] " +
      "[--bases <file>] | " +
      "verify --network <folder> --rpc <url> [--tag <TAG>]",
  );
}
