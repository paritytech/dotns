# DotnsReverseResolver

Reverse resolver — maps an account to its primary `.dot` name. Reads are fail-closed against current ownership.

## What it does

Two write paths:
- `setReverseName(addr, name)` — seeder, restricted to the registrar/controller; sets a primary on a fresh reserved registration when the registrant has none.
- `claimReverseRecord(label)` — self-service for any current holder; the resolver checks `registrar.ownerOf(namehash(label)) == caller` before writing (`NotNameOwner` otherwise).

`nameOf(addr)` re-validates current ownership against the registrar before returning, so an address that transferred its primary away resolves to `""` until it claims a name it currently holds. Past ownership is never sufficient.

UUPS-upgradeable, `Ownable`.

## Notes

- The security guarantee is the fail-closed read, not eager cleanup. A registrar that reverts on the ownership check is treated as "not owned" (empty string).
