# DotnsProtocolRegistry

The protocol's on-chain address book. Maps well-known `bytes32` role keys to the contract that currently fills each role, so every other dotNS contract discovers its siblings at call time instead of hardcoding addresses.

## What it does

A single `key → address` mapping plus a per-address reference count. Resolving a sibling is a `get(key)` view; rewiring the protocol after an upgrade is a single owner `set(key, addr)`. Because consumers re-read the registry on every call, rotating any component (a new PoP controller, a new resolver) takes effect everywhere immediately, with no consumer redeploy.

The refcount lets one address occupy several keys and tracks whether an address is still wired in anywhere. `isRegisteredAddress` is the O(1) peer-trust gate the stores use to authorize protocol writes.

## Keys

`registrar`, `controller`, `registry`, `reverseResolver`, `resolver`, `contentResolver`, `popRules`, `storeFactory`, `popController`, `popResolver`, `nameEscrow`, `multicall3`, `create3Factory`, `popGateway`.

## Interface

**Reads**
- `get(bytes32 key) → address` — registered address, or `address(0)` if unset. Callers must null-check where required.
- `isRegisteredAddress(address) → bool` — true if the address is wired under at least one key.

**Writes**
- `set(bytes32 key, address addr)` — owner only. Rejects `address(0)` (`ZeroAddress`). Idempotent writes emit nothing; effective changes emit `AddressUpdated(key, addr)`.

UUPS-upgradeable, `Ownable`.

## Notes

- The registry does not verify that a stored address is the contract type its key implies — that is governance's responsibility.
- An address stays "registered" until its last key is rewired away.
