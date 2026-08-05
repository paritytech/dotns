# RootGatewayDispatcher

Non-upgradeable shim that turns a substrate Root-origin dispatch into an EVM-observable caller for the PoP controller. It is the address registered under `popGateway`.

## What it does

Every call hits the `fallback`: it asks revive's System precompile `callerIsRoot()` **in its own frame**, and only if that passes forwards the raw calldata to its immutable target (the PoP controller proxy) via a plain message call, bubbling the return/revert data back verbatim. If the check fails it reverts `NotRoot`. The controller then authorizes the dispatcher by matching `msg.sender` against the `popGateway` registry key.

## Why it is a separate contract

The Root check is only meaningful in the frame that is the *direct* callee of Root. A UUPS implementation runs inside the proxy's `delegatecall`, so the controller cannot ask the precompile from its own frame — the dispatcher can. It holds no storage, never delegatecalls, and its target is fixed at construction, so it cannot be repurposed as an arbitrary-target proxy.

## Interface

- `TARGET() → address` — the controller proxy it forwards to (immutable).
- `fallback()` — non-payable; forwards any calldata after the Root check. The gated controller entry points take no value, so value transfers are rejected at the dispatcher boundary.

## Notes

- Rotating the gateway is a single `set(popGateway, …)` on the protocol registry. To point at a different controller, deploy a new dispatcher (the target is immutable).
