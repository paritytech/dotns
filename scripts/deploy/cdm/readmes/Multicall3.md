# Multicall3

A standard [Multicall3](https://github.com/mds1/multicall3) deployment for batching calls in a single transaction. Generic infrastructure — not dotNS-specific and not an authorization surface.

## What it does

Aggregates an array of calls to arbitrary targets: `aggregate3` / `aggregate3Value` (per-call `allowFailure`), plus the legacy `aggregate`, `tryAggregate`, `blockAndAggregate`, `tryBlockAndAggregate`, and block-info helpers (`getBlockNumber`, `getBasefee`, `getEthBalance`, …).

## Notes

- **Caller context:** targets see Multicall3 as `msg.sender`, not the original account. Use it freely for read batching; only route owner-gated dotNS writes through it if the target explicitly supports that caller model.
- This is a dotNS-specific deterministic deployment (via the dotNS CREATE3 factory), **not** the canonical `0xcA11…` singleton. Resolve its address from the protocol registry's `multicall3` key or the deployment manifest — never hardcode `0xcA11…`.
