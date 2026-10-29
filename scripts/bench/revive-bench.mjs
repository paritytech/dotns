#!/usr/bin/env bun
// Measures the weight and proof size of the critical dotNS paths on pallet-revive, against live
// Asset Hub state, and checks each against the limit it runs under in production:
//
//   gateway     DotnsGateway calls DotnsPopController as Root, under MaxContractCallWeight
//   signed      a user's own transaction, under the normal-class extrinsic limit
//   governance  a Root call enacted by a referendum, under the scheduler's maximum weight
//
// Each path runs in a Root `Utility.batch_all` passed to `DryRunApi_dry_run_call` at the finalized
// head, after the setup calls it needs. Nothing is signed or submitted. With --build, the batch
// first upgrades every proxy and store beacon to the implementations in this checkout's `out/`, so the
// figures are for this checkout's code on live state.
//
// Usage: bun scripts/bench/revive-bench.mjs --network <paseo|polkadot> [--build]
//          [--fail-at <percent>] [--json <file>]
//
// Exits 1 when a path does not fit its limit, uses more than --fail-at percent of it, or fails.

import { ApiPromise, WsProvider } from "@polkadot/api";
import fs from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import {
  concat,
  decodeFunctionResult,
  encodeFunctionData,
  getAddress,
  keccak256,
  parseAbi,
  toHex,
} from "viem";

const NETWORKS = {
  paseo: {
    url: "wss://paseo-asset-hub-next-rpc.polkadot.io",
    manifest: "deployments/paseo-assethub/420420417.json",
  },
  polkadot: {
    url: "wss://polkadot-asset-hub-rpc.polkadot.io",
    manifest: "deployments/polkadot/420420419.json",
  },
};

// UUPS proxies, and the StoreFactory call that moves each store beacon to a new implementation
// (the factory owns the beacons).
const PROXIES = [
  "DotnsProtocolRegistry",
  "DotnsRegistry",
  "DotnsRegistrar",
  "DotnsRegistrarController",
  "DotnsNameEscrow",
  "DotnsResolver",
  "DotnsContentResolver",
  "DotnsReverseResolver",
  "DotnsPopResolver",
  "DotnsPopController",
  "PopRules",
  "DotnsNameWhitelist",
  "StoreFactory",
];
const STORES = {
  LabelStore: "upgradeLabelStoreImplementation",
  UserStore: "upgradeUserStoreImplementation",
};

// Far above any real limit, so a path that does not fit still gets a figure. A dry run does not
// check the block limits.
const MEASURE_LIMIT = { refTime: 20_000_000_000_000n, proofSize: 128n << 20n };
// Binary-search resolution for signed calls.
const RESOLUTION = { refTime: 50_000_000n, proofSize: 4096n };
// Used when a deployed controller predates the constant.
const DEFAULT_QUEUE_STEPS = 4n;
const MAX_DEPOSIT = (1n << 128n) - 1n;
const CHAT_KEY = "0x04" + "11".repeat(64);
const ANY_ACCOUNT = "5C4hrfjw9DjXZTzV3MwzrrAr9P1MJhSrvWGWqi1eSuyUpnhM";

const abi = parseAbi([
  "function issueDeviceNameWithReservation(((string label, address user, bytes chatKey) issuance, string reservedLabel) params)",
  "function issueDeviceName((string label, address user, bytes chatKey) params)",
  "function reservePersonhoodName((address user, string label) params)",
  "function issuePersonhoodName((string label, address user, (uint8 kind, string deviceLabel, bytes chatKey) link) params)",
  "function expireReservation(string label)",
  "function claimLabelStore() returns (bool)",
  "function MAX_QUEUE_STEPS_PER_CALL() view returns (uint256)",
  "function MAX_RESERVATION_QUEUE() view returns (uint16)",
  "function version() view returns (string)",
  "function tldNode() view returns (bytes32)",
  "function recordExists(bytes32 node) view returns (bool)",
  "function grantName(string label, address user)",
  "function grantNames(string[] labels, address user)",
  "function requestName(string label, string reason, address user)",
  "function setWindow(uint64 startsIn, uint64 duration)",
  "function maxGrantBatch() view returns (uint16)",
  "function maxClaimants() view returns (uint16)",
  "function maxReasonBytes() view returns (uint256)",
  "function owner() view returns (address)",
  "function upgradeToAndCall(address newImplementation, bytes data)",
  "function upgradeLabelStoreImplementation(address newImplementation)",
  "function upgradeUserStoreImplementation(address newImplementation)",
]);

const { values: args } = parseArgs({
  options: {
    network: { type: "string" },
    build: { type: "boolean", default: false },
    "fail-at": { type: "string", default: "90" },
    json: { type: "string" },
  },
});
const net = NETWORKS[args.network];
if (!net) throw new Error(`--network must be one of ${Object.keys(NETWORKS).join(", ")}`);
const failAt = Number(args["fail-at"]);

const repo = path.resolve(import.meta.dirname, "../..");
const manifest = JSON.parse(fs.readFileSync(path.join(repo, net.manifest), "utf8"));
const CONTROLLER = manifest.DotnsPopController;
const WHITELIST = manifest.DotnsNameWhitelist;

const api = await ApiPromise.create({
  provider: new WsProvider(net.url, 1000, {}, 600_000),
  noInitWarn: true,
});
const head = await api.rpc.chain.getFinalizedHead();
const at = await api.at(head);
const blockNumber = (await api.rpc.chain.getHeader(head)).number.toNumber();

const weightOf = (w) => ({ refTime: BigInt(w.refTime), proofSize: BigInt(w.proofSize) });
const LIMITS = {
  gateway: weightOf(api.consts.dotnsGateway.maxContractCallWeight.toJSON()),
  signed: weightOf(api.consts.system.blockWeights.toJSON().perClass.normal.maxExtrinsic),
  governance: weightOf(api.consts.scheduler.maximumWeight.toJSON()),
};

// Chain reads and call builders

async function read(to, functionName, fnArgs = []) {
  const data = encodeFunctionData({ abi, functionName, args: fnArgs });
  const r = (await at.call.reviveApi.call(ANY_ACCOUNT, to, 0, null, null, data)).toJSON();
  const out = r.result?.ok;
  // Bit 0 of the flags is REVERT.
  if (!out || (out.flags.bits & 1) !== 0) throw new Error(`${functionName} reverted on ${to}`);
  return decodeFunctionResult({ abi, functionName, data: out.data });
}

async function readOr(fallback, ...readArgs) {
  try {
    return await read(...readArgs);
  } catch {
    return fallback;
  }
}

const accountOf = async (h160) => (await at.call.reviveApi.accountId(h160)).toString();

const contractCall = (to, functionName, fnArgs, weight = MEASURE_LIMIT) =>
  api.tx.revive.call(to, 0, weight, MAX_DEPOSIT, encodeFunctionData({ abi, functionName, args: fnArgs }));

// Fails the batch when the inner call fails, unlike `dispatch_as`.
const asSigned = (account, call) =>
  api.tx.utility.dispatchAsFallible({ system: { Signed: account } }, call);

// Funds an account so it can pay the fees and storage deposits of its calls.
const fund = (account) => api.tx.balances.forceSetBalance(account, 10n ** 22n);

// --build: upgrade every proxy and store beacon to this checkout's implementations

async function buildUpgrades() {
  const calls = [];
  const upgrade = async (target, artifact, functionName, fnArgs) => {
    const owner = getAddress(await read(target, "owner"));
    const ownerAccount = await accountOf(owner);
    const file = path.join(repo, "out", `${artifact}.sol`, `${artifact}.json`);
    const initcode = JSON.parse(fs.readFileSync(file, "utf8")).bytecode.object;
    const salt = keccak256(toHex(`dotns-bench-${artifact}`));
    const impl = getAddress(
      "0x" + keccak256(concat(["0xff", owner, salt, keccak256(initcode)])).slice(26),
    );
    calls.push(
      fund(ownerAccount),
      asSigned(ownerAccount, api.tx.revive.instantiateWithCode(0, MEASURE_LIMIT, MAX_DEPOSIT, initcode, "0x", salt)),
      asSigned(ownerAccount, contractCall(target, functionName, fnArgs(impl))),
    );
  };
  for (const name of PROXIES) {
    await upgrade(manifest[name], name, "upgradeToAndCall", (impl) => [impl, "0x"]);
  }
  for (const [store, functionName] of Object.entries(STORES)) {
    await upgrade(manifest.StoreFactory, store, functionName, (impl) => [impl]);
  }
  return calls;
}

// Dry runs

async function dryRun(calls) {
  const tx = api.tx.utility.batchAll(calls);
  const r = (await at.call.dryRunApi.dryRunCall({ system: "Root" }, tx, 5)).toJSON();
  const exec = r.ok?.executionResult;
  if (!exec) throw new Error(`dry run rejected: ${JSON.stringify(r).slice(0, 300)}`);
  const info = exec.ok ?? exec.err.postInfo;
  return { ok: !!exec.ok, error: exec.err?.error, weight: weightOf(info.actualWeight) };
}

const errorName = (e) => {
  if (!e?.module) return JSON.stringify(e);
  const meta = api.registry.findMetaError({
    index: api.createType("u8", e.module.index),
    error: api.createType("[u8;4]", e.module.error),
  });
  return `${meta.section}.${meta.name}`;
};

// A Root call: its cost is the batch's weight with the call minus the batch's weight without it.
async function measureRoot(calls, measure) {
  const base = await dryRun([...calls, api.tx.system.remark("0x")]);
  if (!base.ok) return { error: `setup failed: ${errorName(base.error)}` };
  const roomy = await dryRun([...calls, measure(MEASURE_LIMIT)]);
  if (!roomy.ok) return { error: `fails: ${errorName(roomy.error)}` };
  return {
    refTime: roomy.weight.refTime - base.weight.refTime,
    proofSize: roomy.weight.proofSize - base.weight.proofSize,
  };
}

// A signed call: a dispatch on behalf of an account reports its declared weight, so the cost is
// the smallest limit, in each dimension, under which the call still succeeds.
async function measureSigned(calls, measure) {
  const runs = async (w) => (await dryRun([...calls, measure(w)])).ok;
  const roomy = await dryRun([...calls, measure(MEASURE_LIMIT)]);
  if (!roomy.ok) return { error: `fails: ${errorName(roomy.error)}` };
  const search = async (dim) => {
    let lo = 0n;
    let hi = MEASURE_LIMIT[dim];
    while (hi - lo > RESOLUTION[dim]) {
      const mid = (lo + hi) / 2n;
      if (await runs({ ...MEASURE_LIMIT, [dim]: mid })) hi = mid;
      else lo = mid;
    }
    return hi;
  };
  return { refTime: await search("refTime"), proofSize: await search("proofSize") };
}

async function bench(prefix, s) {
  const calls = [...prefix, ...s.setup];
  const cost = await (s.signed ? measureSigned : measureRoot)(calls, s.measure);
  if (cost.error) return cost;
  const limit = LIMITS[s.limit];
  const fits = (await dryRun([...calls, s.measure(limit)])).ok;
  const share = (v, max) => Number((v * 10000n) / max) / 100;
  return {
    ...cost,
    refShare: share(cost.refTime, limit.refTime),
    proofShare: share(cost.proofSize, limit.proofSize),
    fits,
  };
}

// Scenarios

// Fresh users and labels on every run, so nothing collides with live names.
const seed = BigInt(keccak256(toHex(`${blockNumber}-${Date.now()}`))) & ((1n << 64n) - 1n);
let counter = 0n;
const user = () =>
  getAddress("0xbe9c" + seed.toString(16).padStart(16, "0") + (++counter).toString(16).padStart(20, "0"));
const label = () => {
  let n = BigInt(keccak256(toHex(`${seed}-${++counter}`)));
  let out = "zq";
  for (let i = 0; i < 10; i++, n /= 26n) out += String.fromCharCode(97 + Number(n % 26n));
  return out;
};

const reserve = (u, base, w) =>
  contractCall(CONTROLLER, "reservePersonhoodName", [{ user: u, label: base }], w);
const issueDevice = (u, deviceLabel, base, w) => {
  const issuance = { label: deviceLabel, user: u, chatKey: CHAT_KEY };
  return base
    ? contractCall(CONTROLLER, "issueDeviceNameWithReservation", [{ issuance, reservedLabel: base }], w)
    : contractCall(CONTROLLER, "issueDeviceName", [issuance], w);
};
const claim = (u, base, deviceLabel) => (w) =>
  contractCall(
    CONTROLLER,
    "issuePersonhoodName",
    [{ label: base, user: u, link: { kind: 1, deviceLabel, chatKey: "0x" } }],
    w,
  );

// `count` users join the queue for `base`, then each moves to a queue of its own. Their entries
// in `base` are left empty, for the next call on `base` to clear.
function leftEntries(base, count) {
  const users = Array.from({ length: count }, user);
  return {
    join: users.map((u) => reserve(u, base)),
    leave: users.map((u) => reserve(u, label())),
  };
}

// The first numeric container that does not exist yet, and the first one that does.
async function findContainers() {
  const tld = await read(manifest.DotnsProtocolRegistry, "tldNode");
  let free;
  let used;
  for (let i = 0; i < 100 && !(free && used); i++) {
    const suffix = String(i).padStart(2, "0");
    const node = keccak256(concat([tld, keccak256(toHex(suffix))]));
    if (await read(manifest.DotnsRegistry, "recordExists", [node])) used ??= suffix;
    else free ??= suffix;
  }
  return { free, used: used ?? "00" };
}

async function scenarios() {
  const queueSteps = Number(await readOr(DEFAULT_QUEUE_STEPS, CONTROLLER, "MAX_QUEUE_STEPS_PER_CALL"));
  const queueMax = Number(await read(CONTROLLER, "MAX_RESERVATION_QUEUE"));
  const grantBatch = Number(await read(WHITELIST, "maxGrantBatch"));
  const claimants = Number(await read(WHITELIST, "maxClaimants"));
  const reasonBytes = Number(await read(WHITELIST, "maxReasonBytes"));
  const { free, used } = await findContainers();
  const deviceIn = (container) => `${label()}.${container}`;
  // Makes sure `used` exists, for a container that is not there yet on a fresh chain.
  const warm = () => [issueDevice(user(), deviceIn(used))];

  const list = [];
  const add = (name, limit, setup, measure, signed = false) =>
    list.push({ name, limit, setup, measure, signed });

  if (free) {
    const u = user();
    const d = deviceIn(free);
    const base = label();
    add(`Device name + reservation, first in container ${free}`, "gateway", [],
      (w) => issueDevice(u, d, base, w));
  }
  {
    const u = user();
    const d = deviceIn(used);
    const base = label();
    add("Device name + reservation", "gateway", warm(), (w) => issueDevice(u, d, base, w));
  }
  {
    const u = user();
    const d = deviceIn(used);
    add("Device name only", "gateway", warm(), (w) => issueDevice(u, d, undefined, w));
  }
  {
    const u = user();
    const base = label();
    add("Reservation only", "gateway", [], (w) => reserve(u, base, w));
  }
  {
    const base = label();
    const { join, leave } = leftEntries(base, queueSteps);
    const u = user();
    add(`Reservation behind ${queueSteps} left entries`, "gateway", [...join, ...leave],
      (w) => reserve(u, base, w));
  }
  {
    const u = user();
    const base = label();
    const d = deviceIn(used);
    add("Personhood claim, linked to the device name", "gateway",
      [...warm(), issueDevice(u, d, base)], claim(u, base, d));
  }
  {
    const u = user();
    const base = label();
    const d = deviceIn(used);
    const { join, leave } = leftEntries(base, queueSteps);
    add(`Personhood claim behind ${queueSteps} left entries`, "gateway",
      [...warm(), ...join, issueDevice(u, d, base), ...leave], claim(u, base, d));
  }
  {
    const u = user();
    const account = await accountOf(u);
    add("claimLabelStore, first settlement", "signed",
      [...warm(), issueDevice(u, deviceIn(used)), fund(account)],
      (w) => asSigned(account, contractCall(CONTROLLER, "claimLabelStore", [], w)), true);
  }
  {
    // Permissionless, so it runs as Root: the cost does not depend on the caller.
    const base = label();
    const { join, leave } = leftEntries(base, queueMax);
    add(`expireReservation on ${queueMax} left entries`, "signed", [...join, ...leave],
      (w) => contractCall(CONTROLLER, "expireReservation", [base], w));
  }
  {
    const labels = Array.from({ length: grantBatch }, label);
    const u = user();
    add(`grantNames, ${grantBatch} names`, "governance", [],
      (w) => contractCall(WHITELIST, "grantNames", [labels, u], w));
  }
  {
    // Claims come from users: Root cannot request a name.
    const name = label();
    const reason = "r".repeat(reasonBytes);
    const submitter = await accountOf(user());
    const requests = Array.from({ length: claimants }, () =>
      asSigned(submitter, contractCall(WHITELIST, "requestName", [name, reason, user()])));
    const winner = user();
    add(`grantName clearing ${claimants} claims`, "governance",
      [contractCall(WHITELIST, "setWindow", [0n, 86400n]), fund(submitter), ...requests],
      (w) => contractCall(WHITELIST, "grantName", [name, winner], w));
  }
  return list;
}

// Run and report

const gas = (v) => `${(Number(v) / 1e9).toFixed(1)}B`;
const kib = (v) => `${(Number(v) / 1024).toFixed(0)} KiB`;
const pct = (v) => `${v.toFixed(1)}%`;

const version = await readOr("unknown", CONTROLLER, "version");
const prefix = args.build ? await buildUpgrades() : [];
const target = args.build ? "this checkout" : `deployed ${version}`;
console.log(`${args.network} at block ${blockNumber}, ${target}`);

const rows = [];
for (const s of await scenarios()) {
  const r = await bench(prefix, s);
  const share = r.error ? undefined : Math.max(r.refShare, r.proofShare);
  const result = r.error ?? (!r.fits ? "does not fit" : share > failAt ? `over ${failAt}%` : "ok");
  rows.push({ name: s.name, limit: s.limit, ...r, share, result });
  const figure = r.error ? "" : `${pct(share).padStart(7)} of ${s.limit} limit  `;
  console.log(`${s.name.padEnd(52)} ${figure}${result}`);
}
await api.disconnect();

const limits = Object.entries(LIMITS)
  .map(([k, l]) => `${k} ${gas(l.refTime)} / ${kib(l.proofSize)}`)
  .join(", ");
const summary = [
  `### ${args.network}: ${target}`,
  "",
  `Block ${blockNumber}. Limits: ${limits}. A path fails above ${failAt}% of its limit.`,
  "",
  "| Path | Limit | ref_time | Proof size | Result |",
  "|---|---|---|---|---|",
  ...rows.map((r) =>
    r.error
      ? `| ${r.name} | ${r.limit} | | | ${r.result} |`
      : `| ${r.name} | ${r.limit} | ${gas(r.refTime)} (${pct(r.refShare)}) | ${kib(r.proofSize)} (${pct(r.proofShare)}) | ${r.result} |`,
  ),
  "",
].join("\n");
if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, summary + "\n");
if (args.json) {
  const json = { network: args.network, target, blockNumber, failAt, limits: LIMITS, rows };
  fs.writeFileSync(args.json, JSON.stringify(json, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2));
}
process.exit(rows.every((r) => r.result === "ok") ? 0 : 1);
