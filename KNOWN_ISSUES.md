# Known issues

dotNS carries a small set of constraints worth knowing before deploying or building against it. Most stem from the current pallet-revive runtime rather than from protocol design, and collapse to a no-op once the runtime gains the corresponding capability. Each is described in full where the relevant contract is documented in the [README](./README.md#contracts); this file is the consolidated index.

For the security and audit status of the codebase, see [SECURITY.md](./SECURITY.md).

| # | Issue | Type | Resolves when |
| :- | :---- | :--- | :------------ |
| 1 | Deferred LabelStore deployment | Runtime | pallet-revive charges the storage deposit of Root writes |
| 2 | No standalone user-status mapping | Current implementation | A dedicated status mapping is added, if ever needed |
| 3 | Clearing hides records rather than erasing them | Current implementation | Deliberate; no change planned |
| 4 | Root-written storage refunds deposits nobody paid | Runtime | pallet-revive fixes contract-issues#284 |
| 5 | A revoked personhood holder stays registered in the gateway pallet | Gateway pallet | The gateway pallet gains a Root call that clears an account's names and alias |

## 1. Deferred LabelStore deployment

**Type:** runtime limitation.

A gateway-path issuance runs under Root, and every storage slot a Root dispatch writes records a deposit that pallet-revive never charges (see [Root-written storage refunds deposits nobody paid](#4-root-written-storage-refunds-deposits-nobody-paid)). Deploying the user's `LabelStore` at that moment would add a whole contract of such slots, so the controller stamps a pending-claim entry instead, and the user settles it later by calling `claimLabelStore` from their own address. Settlement is permissionless: `settlePendingClaims` lets anyone settle a given owner's entries and pay the cost, and settlement always writes the label, so a pending name is never stranded.

**Workaround:** `claimLabelStore` (user-signed) settles a bounded batch of the caller's pending claims, deploying the store on the first write; the caller calls it again while it reports `moreRemaining`.

**Resolution:** once pallet-revive charges the deposit for Root writes, the controller can deploy the store at issuance, the deferred path collapses to a no-op, and issuance becomes one transaction end-to-end.

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

**Workaround:** getting the deposit back is the owner's job, and has to happen before the name is released or transferred, because the delete path moves with the name. Delete each text key with `setText(node, key, "")` and each subname with `deleteSubname`, deepest first, before clearing anything above them; see [README → Clearing records and subnames](./README.md#clearing-records-and-subnames). A subname's owner gets the deposit for its records back only by deleting them while the subname still resolves. Subnames created before the upgrade have no recorded parent, so they are linked (`linkSubname`, permissionless) as part of the upgrade, before anything is cleared.

**Resolution:** deliberate. Visiting every record and subname would make a clear cost grow without bound with what the name holds.

See [README → Clearing records and subnames](./README.md#clearing-records-and-subnames).

## 4. Root-written storage refunds deposits nobody paid

**Type:** runtime limitation.

pallet-revive records a storage deposit for a slot written under a Root dispatch but never charges it ([contract-issues#284](https://github.com/paritytech/contract-issues/issues/284)). When a signed transaction later zeroes that slot, the refund is paid out of deposits other users made to the same contract on Asset Hub Paseo and Polkadot, and the call reverts on a runtime without that deposit backend, such as Asset Hub Kusama. The reverse also holds: a slot a user paid for and Root zeroes refunds nobody.

In dotNS, Root writes the registry record, the registrar state and the escrow position of every name it mints, and the label in the owner's LabelStore when they have one. A Root registerReserved for an owner with no store also deploys it; the gateway defers it (see [Deferred LabelStore deployment](#1-deferred-labelstore-deployment)). Gateway-issued names are soulbound and never released, but reserved names minted by governance can be, and their release and reclaim zero some of those slots, so the refund is funded by other users' deposits. The record and subname deletes in [issue 3](#3-clearing-hides-records-rather-than-erasing-them) only zero slots their owner wrote, never Root-written ones. Revocation runs under Root. For a name registered on the signed public path, and for any subname its holder created, it zeroes slots the holder paid for (the token, the registry record, the escrow position, a deleted subname), so their storage deposit is refunded to nobody. A name Root minted, through the gateway or the reserved path, is the balanced case, because Root zeroes slots Root wrote. A revoked holder gets back the escrow deposit for the name, not the storage deposit behind it. The escrow deposit is credited under Root too, so when the holder had no balance waiting, the slot that holds the credit is Root-written: claiming it refunds a storage deposit nobody paid, out of other users' deposits on Paseo and Polkadot, and reverts on a runtime without that deposit backend.

**Resolution:** a pallet-revive fix for contract-issues#284. Nothing in the contracts depends on the drift, so the fix lands without a contract change.

## 5. A revoked personhood holder stays registered in the gateway pallet

**Type:** gateway pallet limitation.

The dotNS gateway pallet keeps its own record of the names each account holds (`AccountNames`) and of each person's alias. Its only calls are `reserve_name`, `register_name`, the allowance calls and `set_dispatcher_address`, so nothing can update or clear those records. Governance revocation clears everything the contracts hold about a name (see [README → Revoking a name](./README.md#revoking-a-name)), but the pallet's records stay. The pallet then rejects that account with `AccountAlreadyRegistered` and that person with `AliasAlreadyRegistered`, so a revoked personhood holder cannot get a personhood name through the gateway again, under the same account or another one.

**Workaround:** none in the contracts. The revoked name itself is free again and can be issued to someone else or registered on the public path.

**Resolution:** a Root call in the gateway pallet that clears an account's names and alias, dispatched in the same governance batch as the revocation.
