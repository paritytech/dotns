# Known issues

DotNS carries a small set of constraints worth knowing before deploying or building against it. Most stem from the current pallet-revive runtime rather than from protocol design, and collapse to a no-op once the runtime gains the corresponding capability. Each is described in full where the relevant contract is documented in the [README](./README.md#contracts); this file is the consolidated index.

For the security and audit status of the codebase, see [SECURITY.md](./SECURITY.md).

| # | Issue | Type | Resolves when |
| :- | :---- | :--- | :------------ |
| 1 | Deferred LabelStore deployment | Runtime | Runtime allows root-origin contract deployment |
| 2 | No standalone user-status mapping | Current implementation | A dedicated status mapping is added, if ever needed |

## 1. Deferred LabelStore deployment

**Type:** runtime limitation.

Substrate Root cannot deploy a contract on behalf of an account it does not control, so a per-user `LabelStore` cannot be created at the moment a Pop-gateway issuance writes the name. The controller stamps a pending-claim entry instead, and the user settles it later by calling `claimLabelStore` once from their own address. Pending-claim entries carry a bounded TTL and `expirePendingClaim` is permissionless, so the slot frees itself if a user never claims.

**Workaround:** `claimLabelStore` (user-signed) settles the whole pending pile and deploys the store.

**Resolution:** when the runtime supports root-origin contract deployment, the deferred path collapses to a no-op and issuance becomes one transaction end-to-end.

See [README → DotnsPopController](./README.md#early-testnet-quirk-labelstore-deployment).

## 2. No standalone user-status mapping

**Type:** current implementation.

The Pop gateway does not write a dedicated user-status mapping. It materialises the PoP flow through gateway-issued labels, PoP resolver records, and reservation queue state; user tier checks for public pricing read status from the personhood precompile and context, not from stored state.

**Resolution:** a dedicated status mapping could be added if a use case requires it; the current design is deliberate, not a defect.

See [README → DotnsPopController](./README.md#dotnspopcontroller).
