#!/usr/bin/env bun
// Register generated DotNS deployment assets in a CDM contract registry.
//
// Takes the asset directory produced by `scripts/cdm/generate.ts` and, for
// each contract: uploads its metadata (description, readme, ABI) to the
// Bulletin chain, then calls `publishLatest(name, address, metadataCid)` on
// the CDM registry contract on Asset Hub. After this, any CDM consumer can
// `cdm install @dotns/<package>` and resolve the current addresses — no more
// chasing address changes across redeploys.
//
// Local usage (preset network):
//   bun run cdm:register -- \
//     --metadata .generated/dotns-cdm/metadata.json \
//     --name paseo \
//     --suri "<mnemonic or //DevAccount>"
//
// Custom endpoints (e.g. previewnet):
//   bun run cdm:register -- \
//     --metadata .generated/dotns-cdm/metadata.json \
//     --name custom \
//     --assethub-url wss://... --bulletin-url wss://... \
//     --registry-address 0x... \
//     --suri "$CDM_SURI"
//
// The signer can also come from the CDM_SURI env var (preferred in CI — keeps
// the secret out of shell history and process lists).
//
// Behavior notes:
//   - Idempotent: contracts whose latest registry entry already matches the
//     manifest address AND metadata CID are skipped, so re-running after a
//     partial failure only does the remaining work. (Registry versions are an
//     on-chain counter; skipping avoids burning versions on no-op re-runs.)
//   - Metadata is uploaded to Bulletin BEFORE registration, so the registry
//     never points at content that isn't stored.
//   - First registration of a package claims its name for the signing
//     account; only that owner can publish subsequent versions.
//   - `--dry-run` connects, checks ownership/idempotence, prints the plan,
//     and submits nothing.

import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { parseArgs } from "node:util";
import {
    CONTRACTS_REGISTRY_ABI,
    MetadataPublisher,
    STORAGE_DEPOSIT_LIMIT,
    type Metadata,
} from "@parity/cdm-builder";
import {
    createCdmChainClient,
    getChainPreset,
    prepareSignerFromSuri,
    ss58Address,
} from "@parity/cdm-env";
import { BulletinPreparer, DEFAULT_CLIENT_CONFIG } from "@parity/product-sdk-cloud-storage";
import { createContractFromClient } from "@parity/product-sdk-contracts";
import { batchSubmitAndWatch } from "@parity/product-sdk-tx";

const { values: flags } = parseArgs({
    options: {
        metadata: { type: "string" },
        name: { type: "string", short: "n", default: "paseo" },
        suri: { type: "string" },
        "assethub-url": { type: "string" },
        "bulletin-url": { type: "string" },
        "registry-address": { type: "string" },
        "dry-run": { type: "boolean", default: false },
        "batch-size": { type: "string", default: "4" },
        "gas-buffer-percent": { type: "string", default: "100" },
        help: { type: "boolean", short: "h" },
    },
});

if (flags.help || !flags.metadata) {
    console.log(
        `Usage: bun run cdm:register -- --metadata <path> --suri <suri> [--name paseo|custom] [--assethub-url <ws>] [--bulletin-url <ws>] [--registry-address <0x..>] [--dry-run] [--batch-size 4] [--gas-buffer-percent 100]\n` +
            `The suri may also be provided via the CDM_SURI env var.`,
    );
    process.exit(flags.help ? 0 : 1);
}

const batchSize = Number(flags["batch-size"]);
const gasBufferPercent = Number(flags["gas-buffer-percent"]);
if (!Number.isInteger(batchSize) || batchSize <= 0) throw new Error("Invalid --batch-size");
if (!Number.isFinite(gasBufferPercent) || gasBufferPercent < 0) {
    throw new Error("Invalid --gas-buffer-percent");
}

const manifestPath = resolve(flags.metadata);
const manifestDir = dirname(manifestPath);
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
if (manifest.version !== 1 || !manifest.contracts?.length) {
    throw new Error(`Invalid CDM manifest: ${manifestPath}`);
}

// Endpoints: preset by name, or fully explicit with --name custom.
const preset = flags.name === "custom" ? undefined : getChainPreset(flags.name);
const assethubUrl = flags["assethub-url"] ?? preset?.assethubUrl;
const bulletinUrl = flags["bulletin-url"] ?? preset?.bulletinUrl;
const registryAddress =
    flags["registry-address"] ?? manifest.registry ?? preset?.registryAddress;
if (!assethubUrl || !bulletinUrl || !registryAddress) {
    throw new Error(
        "Missing endpoints. Use --name <preset>, or pass --assethub-url, --bulletin-url, and --registry-address.",
    );
}

const suri = flags.suri ?? process.env.CDM_SURI;
if (!suri) throw new Error("Missing signer. Pass --suri or set CDM_SURI.");

interface ManifestContract {
    name: string;
    cdmPackage: string;
    address: string;
    description?: string;
    abiPath: string;
    readmePath: string;
}

// Build the CDM metadata payloads. published_at comes from the manifest's
// generatedAt (not "now") so the payload bytes — and therefore the Bulletin
// CIDs — are deterministic for a given generated asset directory. That
// determinism is what makes the idempotence check below possible.
const publishedAt = manifest.generatedAt ?? new Date().toISOString();
const entries = (manifest.contracts as ManifestContract[]).map((contract) => {
    if (!/^@[A-Za-z0-9_-]+\/[A-Za-z0-9_-]+$/.test(contract.cdmPackage)) {
        throw new Error(`Invalid CDM package name: ${contract.cdmPackage}`);
    }
    if (!/^0x[0-9a-fA-F]{40}$/.test(contract.address)) {
        throw new Error(`Invalid address for ${contract.cdmPackage}: ${contract.address}`);
    }
    const abiRaw = JSON.parse(readFileSync(resolve(manifestDir, contract.abiPath), "utf8"));
    const abi = Array.isArray(abiRaw) ? abiRaw : abiRaw.abi;
    if (!abi?.length) throw new Error(`Empty ABI: ${contract.abiPath}`);

    const metadata: Metadata = {
        publish_block: 0,
        published_at: publishedAt,
        description: contract.description ?? "",
        readme: readFileSync(resolve(manifestDir, contract.readmePath), "utf8"),
        authors: manifest.authors ?? [],
        homepage: manifest.homepage ?? "",
        repository: manifest.repository ?? "",
        abi,
    };
    const bytes = new TextEncoder().encode(JSON.stringify(metadata));
    return { ...contract, metadata, bytes };
});

const bulletinPreparer = new BulletinPreparer();
async function computeBulletinCid(bytes: Uint8Array): Promise<string> {
    // Metadata is a description + readme + ABI — tens of KB. Anything near the
    // Bulletin chunking threshold (2 MiB) would need a chunked upload, which
    // MetadataPublisher doesn't do; fail clearly instead of mid-publish.
    if (bytes.length > DEFAULT_CLIENT_CONFIG.chunkingThreshold) {
        throw new Error(
            `Metadata payload of ${bytes.length} bytes exceeds the Bulletin single-tx threshold`,
        );
    }
    const { cid } = await bulletinPreparer.prepareStore(bytes);
    return cid.toString();
}

function bufferWeight(weight: { ref_time: bigint; proof_size: bigint }, percent: number) {
    const scale = (value: bigint) => (value * BigInt(100 + percent) + 99n) / 100n;
    return { ref_time: scale(weight.ref_time), proof_size: scale(weight.proof_size) };
}

const signer = prepareSignerFromSuri(suri);
const origin = ss58Address(signer.publicKey);
console.log(`Registry:  ${registryAddress} (${flags.name})`);
console.log(`Asset Hub: ${assethubUrl}`);
console.log(`Bulletin:  ${bulletinUrl}`);
console.log(`Signer:    ${origin}`);

const client = await createCdmChainClient({
    assethubUrl,
    bulletinUrl,
    chainName: flags.name,
});

try {
    // Contract calls require a mapped account; harmless if already mapped.
    // Skipped for --dry-run, which must submit no transactions at all.
    if (!flags["dry-run"]) {
        try {
            await client.assetHub.tx.Revive.map_account().signAndSubmit(signer);
        } catch {
            // Already mapped (the usual case after a first run).
        }
    }

    const registry = createContractFromClient(
        client.raw.assetHub,
        client.descriptors.assetHub,
        registryAddress,
        CONTRACTS_REGISTRY_ABI,
        { defaultSigner: signer, defaultOrigin: origin },
        // biome-ignore lint: the generated contract surface is dynamic
    ) as any;

    const cids = await Promise.all(entries.map((entry) => computeBulletinCid(entry.bytes)));

    // Idempotence probe: skip contracts whose latest registry entry already
    // matches this manifest exactly (same address, same metadata CID).
    const unwrapOption = (value: unknown): { isSome: boolean; value?: unknown } =>
        value && typeof value === "object" && "isSome" in value
            ? (value as { isSome: boolean; value: unknown })
            : { isSome: false };

    const work: { entry: (typeof entries)[number]; cid: string }[] = [];
    for (let i = 0; i < entries.length; i++) {
        const entry = entries[i];
        const [addressResult, uriResult] = await Promise.all([
            registry.getAddress.query(entry.cdmPackage, { origin }),
            registry.getMetadataUri.query(entry.cdmPackage, { origin }),
        ]);
        const onChainAddress = unwrapOption(addressResult.value);
        const onChainUri = unwrapOption(uriResult.value);
        const unchanged =
            onChainAddress.isSome &&
            String(onChainAddress.value).toLowerCase() === entry.address.toLowerCase() &&
            onChainUri.isSome &&
            onChainUri.value === cids[i];
        if (unchanged) {
            console.log(`  = ${entry.cdmPackage} already registered (unchanged), skipping`);
        } else {
            work.push({ entry, cid: cids[i] });
        }
    }

    if (work.length === 0) {
        console.log("Nothing to do — all contracts already registered with this metadata.");
        process.exit(0);
    }

    // Dry-run the registry calls up front: catches name-ownership conflicts
    // ("Unauthorized": the package was first published by a different account)
    // and produces the gas limits for the real submission.
    const prepared = [];
    for (const { entry, cid } of work) {
        const query = await registry.publishLatest.query(entry.cdmPackage, entry.address, cid, {
            origin,
        });
        if (!query.success || !query.gasRequired) {
            const detail = JSON.stringify(query.value ?? query, (_k, v) =>
                typeof v === "bigint" ? v.toString() : v,
            );
            throw new Error(`Registry dry-run failed for ${entry.cdmPackage}: ${detail}`);
        }
        prepared.push({
            entry,
            cid,
            gasLimit: bufferWeight(query.gasRequired, gasBufferPercent),
        });
        console.log(`  + ${entry.cdmPackage} → ${entry.address} (${cid})`);
    }

    if (flags["dry-run"]) {
        console.log(`Dry run: would publish ${prepared.length} contracts. No transactions sent.`);
        process.exit(0);
    }

    // Upload metadata to Bulletin FIRST: the registry must never point at
    // content that isn't stored. (A failure here costs nothing on-chain.)
    const publisher = new MetadataPublisher(signer, client.bulletin, client.raw.bulletin);
    const uploaded = await publisher.publishBatch(prepared.map(({ entry }) => entry.metadata));
    uploaded.cids.forEach((cid, i) => {
        if (cid !== prepared[i].cid) {
            throw new Error(
                `CID mismatch for ${prepared[i].entry.cdmPackage}: computed ${prepared[i].cid}, stored ${cid}`,
            );
        }
    });
    console.log(`Uploaded ${uploaded.cids.length} metadata payloads to Bulletin`);

    // Then register on Asset Hub in batches.
    const calls = [];
    for (const { entry, cid, gasLimit } of prepared) {
        calls.push(
            await registry.publishLatest.prepare(entry.cdmPackage, entry.address, cid, {
                origin,
                gasLimit,
                storageDepositLimit: STORAGE_DEPOSIT_LIMIT,
            }),
        );
    }
    for (let start = 0; start < calls.length; start += batchSize) {
        const batch = calls.slice(start, start + batchSize);
        if (batchSize === 1) {
            // Direct submission — works on runtimes whose Utility pallet is
            // incompatible with the bundled descriptors (e.g. local dev nets).
            const { entry, cid, gasLimit } = prepared[start];
            const result = await registry.publishLatest.tx(entry.cdmPackage, entry.address, cid, {
                origin,
                gasLimit,
                storageDepositLimit: STORAGE_DEPOSIT_LIMIT,
            });
            if (!result.ok) {
                throw new Error(
                    `publishLatest failed for ${entry.cdmPackage}: ${JSON.stringify(
                        result.dispatchError ?? result,
                        (_k, v) => (typeof v === "bigint" ? v.toString() : v),
                    )}`,
                );
            }
            console.log(`Registered ${start + 1}/${calls.length} contracts`);
        } else {
            const result = await batchSubmitAndWatch(batch, client.assetHub, signer, {
                mode: "batch_all",
                waitFor: "best-block",
            });
            console.log(
                `Registered ${Math.min(start + batchSize, calls.length)}/${calls.length} contracts (${result.txHash})`,
            );
        }
    }

    console.log(`Done: ${prepared.length} contracts published to ${registryAddress}`);
} finally {
    client.destroy();
}
