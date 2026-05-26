# @dotns/abi

Typed `as const` ABIs for the DotNS contracts.

## Install

```bash
bun add @dotns/abi
# or
npm install @dotns/abi
```

## Use

```ts
import { dotnsRegistrarAbi } from "@dotns/abi";
import { createPublicClient, http, getContract } from "viem";

const client = createPublicClient({ transport: http("...") });
const registrar = getContract({
  address: "0x...",
  abi: dotnsRegistrarAbi,
  client,
});

await registrar.read.owner();
```

ABIs are the same across every network DotNS targets; only addresses differ. For per-network addresses see [`@dotns/deployments`](https://github.com/paritytech/dotns/tree/master/packages/deployments).

## Versioning

Versions track the on-chain contract version. `@dotns/abi@1.2.3` matches the contracts published from the `v1.2.3` tag of `paritytech/dotns`. Pre-release tags (`vX.Y.Z-beta.N`) publish under the `beta` dist-tag.
