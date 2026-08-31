# PopRules

The Proof-of-Personhood oracle for dotNS. It classifies labels into tiers, reads each account's personhood status from the precompile, prices registrations and transfers, and holds the cross-flow base-name reservation table that both controllers honor.

## Classification

A label's tier is read from its **stem** (the label with trailing digits removed) and its trailing-digit count, which must be exactly 0 or 2 (1 or 3+ digits are invalid):

| Stem length | Trailing digits | Tier | Who can register |
|---|---|---|---|
| ≤ 5 | — | Reserved | governance / whitelist |
| 6–8 | 0 | PopFull | full-person verified |
| 6–8 | 2 | PopLite | lite-person, gateway-issued |
| ≥ 9 | 0 or 2 | NoStatus | anyone (flat deposit) |

Classification is by *shape*, not by who holds the name — a long `andrewsays` is always a NoStatus-tier label even when a PopFull user owns it.

## Personhood and pricing

Tier is read live (never stored) from the personhood precompile at `0x…0a010000` with the `"dotns"` context. The status byte maps `2 → PopFull`, `1 → PopLite`, anything else → `NoStatus` (fail-closed: an unknown future tier is never treated as higher).

- `priceWithCheck(name, user)` — price plus eligibility; **reverts** on reservation conflict, tier mismatch, or reserved label.
- `priceWithoutCheck(name, user)` — same numbers, non-reverting (reports `Reserved` instead).
- `transferFloor(name, from, to)` — the cross-tier friction: the `max` of a reach component (recipient can't meet the label tier) and a downgrade component (recipient tier < sender tier). Maxed, never summed.

Only NoStatus names (stem ≥ 9) carry a price — the flat `startingPrice` deposit; verified tiers register free.

## Reservation table

A `stem → Reservation { owner, expires, controller }` mapping, expiring after `MAX_RESERVATION_TIME` (12 weeks). Two write paths share it: the public controller during a lite registration, and the PoP controller on each queue-head transition. A cross-user collision reverts; only the stamping controller can release a live entry. Both price reads strip trailing digits first, so any live entry blocks every variant under that stem.

## Interface

**Reads**: `classifyName`, `priceWithCheck`, `priceWithoutCheck`, `price`, `reachFee`, `transferFloor`, `stripDigits`, `isBaseName`, `getBaseNameReservation`, `isBaseNameReserved`.

**Writes (controllers only)**: `reserveBaseName`, `reserveBaseNameForPop`, `releaseBaseName`, `releaseReservationForReclaim`.

**Writes (owner)**: `updateStartingPrice`.

UUPS-upgradeable, `Ownable`.

## Notes

- There is no self-attestation: dotNS only consumes precompile status. Users earn personhood off-chain (People-chain ring proof, propagated to Asset Hub via the alias-accounts pallet).
- To reason about a *live* name, combine three reads: classify the label, read the registrar owner, then read that owner's `"dotns"`-context PoP status.
