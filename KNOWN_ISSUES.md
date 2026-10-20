# Known issues

dotNS carries a small set of constraints worth knowing before deploying or building against it. Most stem from the current pallet-revive runtime rather than from protocol design, and collapse to a no-op once the runtime gains the corresponding capability. Each is described in full where the relevant contract is documented in the [README](./README.md#contracts); this file is the consolidated index.

For the security and audit status of the codebase, see [SECURITY.md](./SECURITY.md).

| # | Issue | Type | Resolves when |
| :- | :---- | :--- | :------------ |
| 1 | Deferred LabelStore deployment | Runtime | Runtime allows root-origin contract deployment |
| 2 | No standalone user-status mapping | Current implementation | A dedicated status mapping is added, if ever needed |
| 3 | Clearing hides records rather than erasing them | Current implementation | Deliberate; no change planned |
| 4 | Root-written storage refunds deposits nobody paid | Runtime | pallet-revive fixes contract-issues#284 |

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

## 3. Clearing hides records rather than erasing them

**Type:** current implementation.

A name's text records and its subnames cannot be listed on chain, so clearing a name, on release or on demand, never visits them. It bumps a version, and every read compares against it. The cleared bytes stay in storage, unreachable, and their storage deposit stays locked: a deposit is released only to whoever signs the transaction that zeroes the slot, and nothing zeroes a slot it cannot find. A later write to the same record reuses the slot. A cleared subname also keeps its row in its holder's `LabelStore`, which has no delete path, so a consumer listing a holder's names must check each one against `DotnsRegistry.owner`, as it already must after a transfer.

Release deletes the address and content hash outright, since each is one slot per name, so their deposit returns to the holder releasing it. Only text records and subnames are left locked.

A subname with no recorded parent is reached by a clear above it only once it, and every level between it and the clear, is linked (`linkSubname`, permissionless). Until then a clear above it leaves it resolving.

**Workaround:** getting the deposit back is the owner's job, and has to happen before the name is released or transferred, because the delete path moves with the name. Delete each text key with `setText(node, key, "")` and each subname with `deleteSubname`, deepest first; see [README → Clearing records and subnames](./README.md#clearing-records-and-subnames). For subnames with no recorded parent, run the backfill in [DEPLOYMENTS.md](./DEPLOYMENTS.md#upgrading-to-record-and-subname-clearing) right after the registry upgrade, so every existing subname is linked before anything is cleared.

**Resolution:** deliberate. Visiting every record and subname would make a clear cost grow without bound with what the name holds.

See [README → Clearing records and subnames](./README.md#clearing-records-and-subnames).

## 4. Root-written storage refunds deposits nobody paid

**Type:** runtime limitation.

pallet-revive records a storage deposit for a slot written under a Root dispatch but never charges it ([contract-issues#284](https://github.com/paritytech/contract-issues/issues/284)). When a signed transaction later zeroes that slot, the refund is paid out of deposits other users made to the same contract on Asset Hub Paseo and Polkadot, and the call reverts on a runtime without that deposit backend, such as Asset Hub Kusama. The reverse also holds: a slot a user paid for and Root zeroes refunds nobody.

In dotNS, Root writes the registry record, the registrar state and the escrow position of every name it mints. Gateway-issued names are soulbound and never released, but reserved names minted by governance can be, and their release and reclaim zero some of those slots, so the refund is funded by other users' deposits. The record and subname deletes in [issue 3](#3-clearing-hides-records-rather-than-erasing-them) only zero slots their owner wrote, never Root-written ones.

**Resolution:** a pallet-revive fix for contract-issues#284. Nothing in the contracts depends on the drift, so the fix lands without a contract change.
