#!/usr/bin/env bun
// Generate CDM registration assets from a DotNS deployment.
//
// Reads three inputs and produces one self-contained asset directory that
// `scripts/cdm/register.ts` can publish to a CDM contract registry:
//
//   1. A deployment manifest (`deployments/<network-folder>/<chain-id>.json`),
//      the flat {"ContractName": "0xaddress"} map written by the deploy
//      pipeline — this is where addresses come from.
//   2. Foundry build artifacts (`out/<File>.sol/<Contract>.json`) — this is
//      where ABIs come from. Run `forge build` first.
//   3. The static descriptor map (`scripts/deploy/cdm/descriptors.json`) + readmes
//      (`scripts/cdm/readmes/*.md`) — checked-in, deployment-independent
//      metadata: CDM package names, descriptions, docs.
//
// Nothing in the output is hand-maintained: addresses and ABIs always come
// from the actual deployment and build, so the generated assets cannot drift
// from what is on chain (see issue: "Generate CDM registration metadata from
// DotNS deployments").
//
// Local usage:
//   forge build
//   bun run cdm:generate -- \
//     --deployment deployments/paseo-assethub/420420417.json \
//     --network paseo-assethub-previewnet
//
// Output (git-ignored):
//   .generated/dotns-cdm/
//     metadata.json     manifest consumed by register.ts
//     abis/*.abi.json   extracted from Foundry artifacts
//     *.md              copied readmes

import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { parseArgs } from "node:util";

const REPO_ROOT = resolve(dirname(Bun.main), "../../..");

const { values: flags } = parseArgs({
    options: {
        deployment: { type: "string" },
        network: { type: "string" },
        out: { type: "string", default: ".generated/dotns-cdm" },
        "cdm-registry": { type: "string" },
        help: { type: "boolean", short: "h" },
    },
});

if (flags.help || !flags.deployment || !flags.network) {
    console.log(
        `Usage: bun run cdm:generate -- --deployment deployments/<folder>/<chain-id>.json --network <name> [--out .generated/dotns-cdm] [--cdm-registry <address>]`,
    );
    process.exit(flags.help ? 0 : 1);
}

const readJson = (path: string) => JSON.parse(readFileSync(path, "utf8"));

interface Descriptor {
    name: string;
    cdmPackage: string;
    description: string;
    sourcePath: string;
    artifactContract: string;
    readme: string;
}

const descriptorsPath = join(REPO_ROOT, "scripts/deploy/cdm/descriptors.json");
const descriptorDoc = readJson(descriptorsPath) as {
    repository: string;
    homepage: string;
    authors: string[];
    contracts: Descriptor[];
};

const deploymentPath = resolve(flags.deployment);
if (!existsSync(deploymentPath)) {
    console.error(`Deployment manifest not found: ${deploymentPath}`);
    process.exit(1);
}
const deployment = readJson(deploymentPath) as Record<string, string>;

// The deploy pipeline's serialization sentinel; never a contract.
delete deployment._seed;

// Every descriptor must have a deployed address — a manifest missing any
// published contract is a partial deploy and must not be registered.
const missing = descriptorDoc.contracts
    .map((d) => d.name)
    .filter((name) => !/^0x[0-9a-fA-F]{40}$/.test(deployment[name] ?? ""));
if (missing.length > 0) {
    console.error(
        `Deployment manifest ${flags.deployment} is missing required contracts:\n  ${missing.join("\n  ")}`,
    );
    process.exit(1);
}

// The reverse — deployed contracts we have no descriptor for — is fine
// (Create3Factory is deployment infrastructure, not a CDM package), but say
// so, in case a new contract was added without a descriptor.
const undescribed = Object.keys(deployment).filter(
    (name) => !descriptorDoc.contracts.some((d) => d.name === name),
);
if (undescribed.length > 0) {
    console.log(`Skipping manifest entries with no CDM descriptor: ${undescribed.join(", ")}`);
}

const outDir = resolve(flags.out);
mkdirSync(join(outDir, "abis"), { recursive: true });

const contracts = descriptorDoc.contracts.map((descriptor) => {
    // Foundry keys artifacts by source file, and every artifact we publish
    // lives in a file named after its contract (<Contract>.sol/<Contract>.json)
    // — including UpgradeableBeacon, which comes from OpenZeppelin.
    const artifactPath = join(
        REPO_ROOT,
        "out",
        `${descriptor.artifactContract}.sol`,
        `${descriptor.artifactContract}.json`,
    );
    if (!existsSync(artifactPath)) {
        console.error(
            `Foundry artifact not found: ${artifactPath}\n` +
                `(descriptor ${descriptor.name} → artifact contract ${descriptor.artifactContract}; run \`forge build\` first)`,
        );
        process.exit(1);
    }
    const abi = readJson(artifactPath).abi;
    if (!Array.isArray(abi) || abi.length === 0) {
        console.error(`Artifact has no ABI: ${artifactPath}`);
        process.exit(1);
    }

    const readmeSource = join(REPO_ROOT, "scripts/deploy/cdm/readmes", descriptor.readme);
    if (!existsSync(readmeSource)) {
        console.error(`Readme not found for ${descriptor.name}: ${readmeSource}`);
        process.exit(1);
    }

    const abiPath = `abis/${descriptor.name}.abi.json`;
    const readmePath = basename(descriptor.readme);
    writeFileSync(join(outDir, abiPath), `${JSON.stringify(abi, null, 2)}\n`);
    copyFileSync(readmeSource, join(outDir, readmePath));

    return {
        name: descriptor.name,
        cdmPackage: descriptor.cdmPackage,
        address: deployment[descriptor.name],
        description: descriptor.description,
        abiPath,
        readmePath,
        sourcePath: descriptor.sourcePath,
        contractName: descriptor.artifactContract,
    };
});

const metadata = {
    version: 1,
    // Also used by register.ts as the published_at timestamp, so re-registering
    // the same generated assets produces byte-identical metadata (and thus the
    // same content CIDs), which is what makes registration idempotent.
    generatedAt: new Date().toISOString(),
    network: flags.network,
    ...(flags["cdm-registry"] ? { registry: flags["cdm-registry"] } : {}),
    repository: descriptorDoc.repository,
    homepage: descriptorDoc.homepage,
    authors: descriptorDoc.authors,
    contracts,
};

writeFileSync(join(outDir, "metadata.json"), `${JSON.stringify(metadata, null, 2)}\n`);
console.log(`Generated CDM assets for ${contracts.length} contracts at ${outDir}`);
