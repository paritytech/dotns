# DotnsRegistrarController

The public, commit-reveal entry point for registering `.dot` names. Anyone can register here; pricing and eligibility are delegated to `PopRules`.

## What it does

**Commit-reveal** defeats front-running:
1. `commit(commitment)` records `keccak256(abi.encode(label, owner, secret, reserved))` with a timestamp.
2. After `minCommitmentAge` (and before `maxCommitmentAge`), `register(registration)` reveals the params alongside payment.

On reveal it validates the label (single DNS label, ≥3 chars), checks availability on the registrar, prices through PopRules, then orchestrates the full side-effect set: mint on the registrar, forward wire-up on the registry, an optional reverse record, the immutable LabelStore write, the escrow deposit, and an inline refund of any overpayment (falling back to the escrow's pull ledger if the inline push fails). Registering a name a prior holder released back to escrow follows the same flow but routes through `escrow.reclaim` instead of a fresh mint. A direct lite-tier registration additionally stamps a 12-week reservation on the bare stem in PopRules.

**Pricing paths.** A direct registration (`msg.sender == owner`) routes through `priceWithCheck`, and the charge becomes a refundable NoStatus deposit. A cross-payer registration (a sponsor paying for a different owner) routes through `priceWithoutCheck`, charges the greater of the owner-side price and the downward transfer floor (never their sum) into the escrow insurance fund, and still requires the *owner's* PoP tier to meet the label — sponsoring an unverified owner reverts `OwnerStatusInsufficient`.

**Whitelist.** `registerReserved` lets whitelisted addresses register reserved labels, bypassing the PoP gate but not the commit-reveal or availability checks. Entries are managed by a dedicated operator role.

## Interface

**Reads**: `available(string) → bool`, `makeCommitment(registration) → bytes32`, `isWhiteListed(address) → bool`.

**Writes**: `commit(bytes32)`, `register(registration)` (payable), `registerReserved(registration)` (whitelist/owner), `whiteListAddress(address, bool)` (operator).

UUPS-upgradeable, `Ownable` + AccessControl (whitelist-operator role), reentrancy-guarded on the payable paths.

## Notes

- Common reverts: `LabelTooShort`, `CommitmentTooNew`/`CommitmentTooOld`, `InsufficientValue`. Reservation and governance conflicts revert `NameReserved`/`GovernanceReserved` on the cross-payer path; the direct path surfaces the same conflicts as `PopError` reverts from PopRules.
- The `secret` is caller-chosen entropy; the same `(label, owner, secret, reserved)` tuple must be passed to both `makeCommitment` and `register`.
