# Known issues

dotNS carries a small set of constraints worth knowing before deploying or building against it. Most stem from the current pallet-revive runtime rather than from protocol design, and collapse to a no-op once the runtime gains the corresponding capability. Each is described in full where the relevant contract is documented in the [README](./README.md#contracts); this file is the consolidated index.

For the security and audit status of the codebase, see [SECURITY.md](./SECURITY.md).

| # | Issue | Type | Resolves when |
| :- | :---- | :--- | :------------ |
| 1 | Deferred LabelStore deployment | Runtime | Runtime allows root-origin contract deployment |
| 2 | No standalone user-status mapping | Current implementation | A dedicated status mapping is added, if ever needed |

## 1. Deferred LabelStore deployment

**Type:** runtime limitation.

Substrate Root cannot deploy a contract on behalf of an account it does not control, so a per-user `LabelStore` cannot be created at the moment a gateway-path issuance writes the name. The controller stamps a pending-claim entry instead, and the user settles it later by calling `claimLabelStore` from their own address. Settlement is permissionless: `settlePendingClaims` lets anyone settle a given owner's entries and pay the cost, and settlement always writes the label, so a pending name is never stranded.

**Workaround:** `claimLabelStore` (user-signed) settles a bounded batch of the caller's pending claims, deploying the store on the first write; the caller calls it again while it reports `moreRemaining`.

**Resolution:** when the runtime supports root-origin contract deployment, the deferred path collapses to a no-op and issuance becomes one transaction end-to-end.

See [README → DotnsPopController](./README.md#early-testnet-quirk-labelstore-deployment).

## 2. No standalone user-status mapping

**Type:** current implementation.

The gateway path does not write a dedicated user-status mapping. It materialises that path through gateway-issued labels, PoP resolver records, and reservation queue state; user tier checks for public pricing read status from the personhood precompile and context, not from stored state.

**Resolution:** a dedicated status mapping could be added if a use case requires it; the current design is deliberate, not a defect.

See [README → DotnsPopController](./README.md#dotnspopcontroller).
