# @dotns/deployments

DotNS contract addresses, keyed by network name.

## Install

```bash
bun add @dotns/deployments
# or
npm install @dotns/deployments
```

## Use

```ts
import { networks } from "@dotns/deployments";

const { chainId, name, addresses } = networks["paseo-previewnet"];
const registrar = addresses.DotnsRegistrar;
```

Pair with [`@dotns/abi`](https://github.com/paritytech/dotns/tree/master/packages/abi) for full viem type inference:

```ts
import { dotnsRegistrarAbi } from "@dotns/abi";
import { networks } from "@dotns/deployments";
import { createPublicClient, http, getContract } from "viem";

const client = createPublicClient({ transport: http("...") });
const registrar = getContract({
  address: networks["paseo-previewnet"].addresses.DotnsRegistrar,
  abi: dotnsRegistrarAbi,
  client,
});

await registrar.read.owner();
```

## Networks

The `networks` object exposes every network DotNS targets, keyed by friendly name. ABIs are the same across networks; only addresses differ.

| Key                | Chain ID  | Notes                              |
| ------------------ | --------- | ---------------------------------- |
| `paseo-previewnet` | 420420417 | Paseo Asset Hub Previewnet (live). |
| `paseo-v2`         | 420420422 | Listed once the v2 deployment lands. |

`networks[key]` only contains networks that have a deployment file in this repo. Networks registered ahead of their first deployment appear once that file lands and the next release ships.

## Versioning

Versions track the on-chain contract version. `@dotns/deployments@1.2.3` matches the addresses deployed for the `v1.2.3` tag of `paritytech/dotns`. Pre-release tags (`vX.Y.Z-beta.N`) publish under the `beta` dist-tag.
