#!/usr/bin/env bun
// Brings names and subnames that predate record and subname clearing into it.
//
// Two jobs, both safe to repeat and both permissionless on chain:
//
//   1. Link every subname that has no recorded parent. Clearing a name reaches the subnames beneath
//      it only through their recorded parents, and a subname created before parents were recorded
//      has none. Each level is linked on its own, because an unlinked subname cannot name its
//      parent. Candidates come from the registry's `NewOwner` events.
//   2. Clear every name the escrow already holds (`--escrow`). Release clears a name as it takes
//      custody, so only names released before that need it.
//
// Reads only, unless `--send` is given, which signs with PRIVATE_KEY.
//
// Usage:
//   bun scripts/js/link-subnames.mjs --rpc-url <url> --registry <address> \
//     [--escrow <address>] [--from-block <n>] [--step <blocks>] [--send]
//
// `--step` splits the event scan into block ranges, for RPC endpoints that cap `eth_getLogs`.

import {
  concat,
  createPublicClient,
  createWalletClient,
  http,
  keccak256,
  parseAbi,
  parseAbiItem,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const NEW_OWNER = parseAbiItem(
  "event NewOwner(bytes32 indexed node, bytes32 indexed label, address owner)",
);

const REGISTRY_ABI = parseAbi([
  "function recordExists(bytes32 node) view returns (bool)",
  "function parentOf(bytes32 node) view returns (bytes32)",
  "function linkSubname(bytes32 parentNode, bytes32 labelhash)",
]);

const ESCROW_ABI = parseAbi([
  "function releasedTokenCount() view returns (uint256)",
  "function releasedTokens(uint256 start, uint256 limit) view returns (uint256[])",
  "function clearReleasedName(uint256 tokenId)",
]);

const ZERO = `0x${"0".repeat(64)}`;
const PAGE = 100n;

function parseArgs(argv) {
  const args = { send: false, fromBlock: 0n, step: 0n };
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    const value = () => {
      const next = argv[++i];
      if (next === undefined) throw new Error(`${flag} needs a value`);
      return next;
    };
    if (flag === "--rpc-url") args.rpcUrl = value();
    else if (flag === "--registry") args.registry = value();
    else if (flag === "--escrow") args.escrow = value();
    else if (flag === "--from-block") args.fromBlock = BigInt(value());
    else if (flag === "--step") args.step = BigInt(value());
    else if (flag === "--send") args.send = true;
    else throw new Error(`unknown flag ${flag}`);
  }
  if (!args.rpcUrl || !args.registry) throw new Error("--rpc-url and --registry are required");
  return args;
}

async function newOwnerLogs(client, registry, fromBlock, step) {
  const latest = await client.getBlockNumber();
  if (step === 0n) {
    return client.getLogs({ address: registry, event: NEW_OWNER, fromBlock, toBlock: latest });
  }
  const logs = [];
  for (let start = fromBlock; start <= latest; start += step) {
    const end = start + step - 1n < latest ? start + step - 1n : latest;
    const range = { address: registry, event: NEW_OWNER, fromBlock: start, toBlock: end };
    logs.push(...(await client.getLogs(range)));
  }
  return logs;
}

async function unlinkedSubnames(client, registry, logs) {
  const seen = new Map();
  for (const log of logs) {
    const { node: parent, label } = log.args;
    const subnode = keccak256(concat([parent, label]));
    if (!seen.has(subnode)) seen.set(subnode, { parent, label, subnode });
  }

  const pending = [];
  for (const entry of seen.values()) {
    const exists = await client.readContract({
      address: registry,
      abi: REGISTRY_ABI,
      functionName: "recordExists",
      args: [entry.subnode],
    });
    if (!exists) continue;
    const parent = await client.readContract({
      address: registry,
      abi: REGISTRY_ABI,
      functionName: "parentOf",
      args: [entry.subnode],
    });
    if (parent === ZERO) pending.push(entry);
  }
  return { scanned: seen.size, pending };
}

async function releasedTokens(client, escrow) {
  const count = await client.readContract({
    address: escrow,
    abi: ESCROW_ABI,
    functionName: "releasedTokenCount",
  });
  const tokens = [];
  for (let start = 0n; start < count; start += PAGE) {
    tokens.push(
      ...(await client.readContract({
        address: escrow,
        abi: ESCROW_ABI,
        functionName: "releasedTokens",
        args: [start, PAGE],
      })),
    );
  }
  return tokens;
}

async function sendAll(client, wallet, calls) {
  for (const call of calls) {
    const hash = await wallet.writeContract(call);
    const receipt = await client.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`${call.functionName} reverted: ${hash}`);
    console.log(`  sent ${call.functionName}(${call.args.join(", ")}) ${hash}`);
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const client = createPublicClient({ transport: http(args.rpcUrl) });
  const chain = {
    id: await client.getChainId(),
    name: "target",
    nativeCurrency: { name: "native", symbol: "native", decimals: 18 },
    rpcUrls: { default: { http: [args.rpcUrl] } },
  };

  const logs = await newOwnerLogs(client, args.registry, args.fromBlock, args.step);
  const { scanned, pending } = await unlinkedSubnames(client, args.registry, logs);
  console.log(`subnames seen: ${scanned}, still to link: ${pending.length}`);
  for (const { parent, label, subnode } of pending) {
    console.log(`  ${subnode} parent=${parent} labelhash=${label}`);
  }

  let custody = [];
  if (args.escrow) {
    custody = await releasedTokens(client, args.escrow);
    console.log(`names in escrow custody: ${custody.length}`);
    for (const tokenId of custody) console.log(`  ${tokenId}`);
  }

  if (!args.send) {
    console.log("dry run: pass --send to submit");
    return;
  }

  const key = process.env.PRIVATE_KEY;
  if (!key) throw new Error("--send needs PRIVATE_KEY");
  const account = privateKeyToAccount(key.startsWith("0x") ? key : `0x${key}`);
  const wallet = createWalletClient({ account, chain, transport: http(args.rpcUrl) });

  await sendAll(
    client,
    wallet,
    pending.map(({ parent, label }) => ({
      address: args.registry,
      abi: REGISTRY_ABI,
      functionName: "linkSubname",
      args: [parent, label],
    })),
  );
  await sendAll(
    client,
    wallet,
    custody.map((tokenId) => ({
      address: args.escrow,
      abi: ESCROW_ABI,
      functionName: "clearReleasedName",
      args: [tokenId],
    })),
  );
  console.log("done");
}

main().catch((error) => {
  console.error(error.message ?? error);
  process.exit(1);
});
