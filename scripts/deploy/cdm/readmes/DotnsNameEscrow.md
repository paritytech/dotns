# DotnsNameEscrow

Custodial vault for dotNS registration deposits and transfer-friction fees. Deposits are bound to the **name (`tokenId`)**, not the depositor, so they travel with the NFT and only unlock when the holder releases the name.

## What it does

**Deposits.** The controller records a deposit per `tokenId` on registration (native token only). The position's recipient rebinds to the current holder on every transfer — transferring a funded name hands the locked deposit to the recipient. Zero-amount positions are valid (free verified registrations) and still releasable.

**Release lifecycle.** `release(tokenId)` (the holder, who must first approve the escrow on the registrar) moves the name into escrow custody and starts a cooldown; `withdraw(tokenId)` after the cooldown credits the deposit to the holder's withdrawal balance; the controller's `reclaim` later hands the name to a new registrant — a position is only reclaimable once it has been both released *and* withdrawn.

**Two pull-payment ledgers, deliberately separate:**
- *Withdrawal ledger* — no cooldown of its own. Receives withdrawn release deposits (the cooldown already ran on the position) and registration overpayments that couldn't be returned inline. Pulled with `claimWithdrawal()`.
- *Refund ledger* — each entry carries its own cooldown clock. Holds transfer-fee overpayments credited by `chargeTransferFee`. Pulled with `claimRefund(id)` / `claimRefundsBatch(ids)`.

Transfer-friction fees (`chargeTransferFee`, registrar only) go to a non-refundable shared **insurance fund**.

## Interface

**Reads**: `getReleasePosition(tokenId)`, `pendingWithdrawal(addr)`, `pendingRefundCount/Ids/refunds(addr, offset, limit)` (paginated, capped), `refundEntry(id)`, `releasedTokens(...)`, `insuranceFund()`, `cooldown()`.

**Writes (holder)**: `release`, `withdraw`, `claimWithdrawal`, `claimRefund`, `claimRefundsBatch`.

**Writes (protocol)**: `deposit`, `creditOverpayment`, `depositInsurance`, `reclaim` (controller only); `chargeTransferFee` (registrar only).

**Writes (owner)**: `updateCooldown` (capped at `MAX_COOLDOWN`, 1 hour).

UUPS-upgradeable, `Ownable`, reentrancy-guarded, `IERC721Receiver` (rejects unsolicited transfers).

## Notes

- The cooldown is a short window — the original payer's uncontested chance to pull a refund before the name is handed out again, not a long-lived lock. Cooldown changes affect only future releases.
- Because the deposit follows the NFT, a NoStatus user cannot recover their deposit by re-registering from a fresh address; the only path back is releasing the name.
