# Known issues

DotNS carries a small set of constraints worth knowing before deploying or building against it. Most stem from the current pallet-revive runtime rather than from protocol design, and collapse to a no-op once the runtime gains the corresponding capability. Each is described in full where the relevant contract is documented in the [README](./README.md#contracts); this file is the consolidated index.

For the security and audit status of the codebase, see [SECURITY.md](./SECURITY.md).

| #   | Issue                                               | Type                     | Resolves when                                        |
| :-- | :-------------------------------------------------- | :----------------------- | :--------------------------------------------------- |
| 1   | Deferred LabelStore deployment                      | Runtime                  | Runtime allows root-origin contract deployment       |
| 2   | Transfer fee is zero until the store is settled     | Runtime (follows from 1) | The holder calls `claimLabelStore`, or 1 is resolved |
| 3   | Root origin is not propagated through delegatecalls | Runtime                  | Runtime propagates origin through delegatecalls      |
| 4   | No standalone user-status mapping                   | Current implementation   | A dedicated status mapping is added, if ever needed  |

## 1. Deferred LabelStore deployment

**Type:** runtime limitation.

Substrate Root cannot deploy a contract on behalf of an account it does not control, so a per-user `LabelStore` cannot be created at the moment a Pop-gateway issuance writes the name. The controller stamps a pending-claim entry instead, and the user settles it later by calling `claimLabelStore` once from their own address. Pending-claim entries carry a bounded TTL and `expirePendingClaim` is permissionless, so the slot frees itself if a user never claims.

**Workaround:** `claimLabelStore` (user-signed) settles the whole pending pile and deploys the store.

**Resolution:** when the runtime supports root-origin contract deployment, the deferred path collapses to a no-op and issuance becomes one transaction end-to-end.

See [README → DotnsPopController](./README.md#early-testnet-quirk-labelstore-deployment).

## 2. Transfer fee is zero until the store is settled

**Type:** runtime limitation; a direct consequence of issue 1.

The registrar derives the transfer-floor price by reading the label from the sender's `LabelStore`. A gateway-issued name held by a user who has not yet called `claimLabelStore` has no readable label on the sender side, so `_quoteTransferFee` returns zero regardless of the recipient's tier. Until the holder settles their store, a downward transfer (for example PopFull to NoStatus) does not charge the cross-tier friction it would otherwise owe.

**Workaround:** clients that consume gateway-issued names should treat `claimLabelStore` as a prerequisite for accurate transfer-time pricing, not just for label discovery.

**Resolution:** clears once issue 1 is resolved.

See [README → DotnsPopController](./README.md#early-testnet-quirk-labelstore-deployment).

## 3. Root origin is not propagated through delegatecalls

**Type:** runtime limitation.

The substrate Root origin is not propagated through delegatecalls, so a UUPS implementation running inside its proxy's delegatecall frame cannot observe Root authority directly. Gateway calls therefore route through the non-proxy `RootGatewayDispatcher`, which is the direct callee of the Root runtime origin and forwards to the controller via a regular message call only after the Root check passes.

**Workaround:** the `RootGatewayDispatcher` shim restores a frame in which the Root check is meaningful.

**Resolution:** when the runtime propagates origin through delegatecalls, the controller can verify Root from its own frame and the dispatcher becomes unnecessary.

See [README → RootGatewayDispatcher](./README.md#rootgatewaydispatcher).

## 4. No standalone user-status mapping

**Type:** current implementation.

The Pop gateway does not write a dedicated user-status mapping. It materialises the PoP flow through gateway-issued labels, PoP resolver records, and reservation queue state; user tier checks for public pricing read status from the personhood precompile and context, not from stored state.

**Resolution:** a dedicated status mapping could be added if a use case requires it; the current design is deliberate, not a defect.

See [README → DotnsPopController](./README.md#dotnspopcontroller).
