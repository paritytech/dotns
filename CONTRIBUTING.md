# Contributing to DotNS

These guidelines apply to the DotNS repository ("dotns"). Contributions are welcome via issues, pull requests, reviews, and testing feedback. Protocol behaviour and the deployments table live in [README.md](./README.md); this file is the contributor mechanics.

## Types of contributing

1. Opening an issue
   - Check whether an issue already exists before creating a new one.
   - If a related issue exists, add details there rather than duplicating.
   - Use issues for bug reports, feature requests, and process suggestions.

2. Resolving an issue
   - Fix with code, tests, documentation, or by demonstrating expected behaviour.
   - Reference the issue number in the pull request and commit messages where relevant.

3. Reviewing open pull requests
   - Review for correctness, security, test coverage, naming, ergonomics, and gas.
   - Flag potential edge cases or missing invariants.

## Opening an issue

When opening an issue, include:

- A short, specific title.
- Expected vs actual behaviour.
- A minimal reproduction where possible (tests or a proof-of-concept).
- Environment details if relevant (Solidity version, Foundry version, chain, etc).

If you are proposing an API or behaviour change, describe:

- The problem being solved.
- Compatibility and migration considerations.
- Any security or UX implications.

## Opening a pull request

- Open pull requests against the `main` branch.
- Link the issue being addressed (or describe the motivation if there is no issue).
- Keep pull requests focused. If a change has multiple concerns, split it into smaller PRs.

Before opening a pull request:

- Run formatting: `forge fmt`
- Run the test suite: `forge test`
- Add or update tests for new behaviour.
- Keep public APIs documented with [NatSpec](https://docs.soliditylang.org/en/latest/natspec-format.html).
- Keep changes small enough to review, or explain the design trade-offs clearly.

## Standards

1. Formatting
   - All contracts and tests should be formatted with `forge fmt`.

2. Interfaces and implementations
   - External-facing contracts should implement and conform to their interfaces.
   - Interfaces should describe public/external functions with NatSpec.
   - Keep implementations aligned with the interface surface area. Avoid unused methods.

3. Tests
   - Add unit tests for behaviour changes.
   - Use fuzz tests where they add meaningful coverage.
   - Prefer readable, behaviour-oriented test names and assertions.
   - Keep tests deterministic unless explicitly fuzzing.

4. Commit hygiene
   - Keep commits logically grouped.
   - Squash when appropriate to keep history clean (maintainers may squash on merge).

## Static analysis and security tooling

DotNS uses automated checks (including static analysis) on pull requests.

Important caveats:

- The repository does not assume static analysis output is definitive.
  - Static analyzers can produce false positives and miss real issues.
  - Reports are treated as a sanity check and a review aid, not as proof of correctness.

- Common reasons for false positives:
  - Upgradeable patterns (proxies, initializers, storage layout assumptions).
  - Custom access control or non-standard authorization flows.
  - Low-level code (assembly) and hand-rolled hashing/namehash logic.
  - Intentional design choices that resemble risky patterns to a tool.

- How to handle a static analysis finding:
  - If it is a true issue, fix it and add tests that would have caught it.
  - If it is a false positive, document why it is safe (PR description is fine) and, where feasible, add a targeted test that demonstrates intended behaviour.

Also note:

- The project does not universally check for zero addresses in every setter or wiring function.
  - Do not assume non-zero address validation exists unless the code explicitly enforces it.
  - If a missing zero-address check is relevant for a specific call path or security property, raise it in review or propose a change with tests.

## Setup

- Build:
  - `forge build`

- Test:
  - `forge test`
  - `forge test --isolate` (useful when debugging test interactions)

## Upgrade-PR workflow

The conventions below apply specifically to PRs that upgrade an already-deployed proxy. They are scoped to the lifetime of the PR and must be removed before merge; the cleanup checklist at the end of this section is the gate reviewers enforce.

### Storage-collision checks

**Storage-layout safety is non-negotiable on every deploy and upgrade path.** The OpenZeppelin validator runs end-to-end on every proxy: on upgrades it diffs the new implementation's storage layout against a pinned `Old.sol` reference snapshot and fails the build if a slot moves, shrinks, or changes type; on fresh deploys it catches unsafe-upgrade-incompatible patterns (constructors, state-variable assignments and immutables in the implementation, `selfdestruct`, raw `delegatecall`, external library linking, missing initialisers, and so on) that would only surface as a bug the first time a future upgrade is attempted. **No deploy or upgrade script in this repository passes `unsafeSkipAllChecks` or any `unsafeAllow` override, and adding one is not on the table. If validation fails, fix the contract, not the script.**

The validator accepts the predecessor either as a compilable artefact in the same project (for example a `FooOld.sol` sibling) or as a stored `referenceBuildInfoDir`. We have chosen the source-file route deliberately: the snapshot is versioned alongside the implementation, reviewable in a diff, and available to `forge build` without any out-of-band fetch. A stored build-info directory would drift out of lockstep with the code reviewers read.

### The `Old.sol` snapshot convention

The `Old.sol` convention has a fixed shape. For a contract `Foo.sol` declaring `contract Foo is ...`, the snapshot file is `FooOld.sol` in the same directory, declaring `contract FooOld is ...` with the pre-upgrade storage layout, imports, inheritance list, and public surface copied verbatim at the moment the upgrade PR is opened. The only mechanical difference is the `Old` suffix on the file name, the contract name, and any sibling interface the snapshot depends on (for example `IFoo.sol` becomes `IFooOld.sol`). Upgrade scripts reference the snapshot through `Options({referenceContract: "FooOld.sol:FooOld"})` on the matching `Upgrades.upgradeProxy` call.

**`Old.sol` snapshots are PR-scoped and must never land on `main`.** They exist only for the upgrade PR that introduces them, so CI and local `forge build` can diff the new layout against the pre-upgrade layout. **Before the PR merges, every `Old.sol` (and every matching `I*Old.sol`) must be deleted, along with the `referenceContract` wiring in the upgrade script.** Once the upgrade is live, the "old" layout is the on-chain deployment, not a file in the repository; keeping the snapshot around after merge would create a phantom contract that future diffs would treat as real code. Reviewers should refuse any PR that ships `Old.sol` files to `main`.

### Fork tests

Fork tests are upgrade-PR scoped. They live in `test/fork/` for the duration of an upgrade PR, paired 1:1 with the upgrade script under `scripts/deploy/`. They run against a local Paseo Asset Hub fork via the ETH-RPC adapter described in the README's deployment note, and they are deleted alongside the upgrade script and the matching `Old.sol` snapshots before merge. Between upgrade PRs the directory is empty.

While a fork test is in flight, skip it with:

```bash
forge test --no-match-path 'test/fork/**'
```

### Cleanup checklist before merging an upgrade PR

1. Delete the upgrade script under `scripts/deploy/`.
2. Delete the paired fork test under `test/fork/`.
3. Delete every `*Old.sol` and `I*Old.sol` referenced only by the upgrade script.
4. Delete temporary forge artefacts: `broadcast/<Script>.s.sol/` and `cache/<Script>.s.sol/`.
5. Update `deployments/<network>/<chainid>.json` with any new proxy addresses.
6. Update the README's deployments table with new proxy addresses (and any new EOA-registered keys).

## Code of conduct

Be respectful and constructive.

- Harassment, abuse, or aggressive behaviour is not acceptable.
- Spam issues/PRs, or contributions unrelated to DotNS, may be closed.
