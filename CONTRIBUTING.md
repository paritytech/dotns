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

- Open pull requests against the `master` branch.
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

## Feature design

Treat the chain as the database. Assume no servers and no indexers. If a feature needs an offchain service to be usable, it is not a DotNS feature.

This has a practical implication: every feature must come with an explicit query path. A client should be able to start from a small set of known contracts and find everything it needs with a bounded number of calls. Every getter is `external view`; controllers and resolvers check authorisation on writes, never on reads; governance key rotation does not break existing read paths because consumers re-resolve their siblings through the protocol registry on every call.

Rules of thumb:

- State is the source of truth. Events are for observability.
- Discovery must be deterministic. If something is created, store where to find it.
- Avoid "scan and reconstruct". Do not require replaying logs from genesis to recover user state.
- Prefer simple keys. `node`, `labelhash`, `owner`, `commitment` should be enough to locate related data.
- If you need lists, make them enumerable onchain with pagination. Do not assume an indexer will build the list.
- If a rule matters for funds or correctness, enforce it onchain. Offchain checks are optional UX.
- If a new record belongs to a single name, it goes on a dedicated resolver, not on the Store. The Store stays labels only.
- A new cross-contract handshake must be expressible as a bounded sequence of view calls, and every step must be tested at the level where it lives: unit for a single-contract behaviour, fuzz for property coverage over random inputs, invariant for properties that must hold across random call sequences, and fork for live-state behaviour.

A quick checklist for a PR adding a feature:

- Where is the canonical state stored?
- From which known contract can a client discover it?
- What are the exact view functions needed to read it without scanning?
- How does a client list relevant items, if listing is required, and how is it paginated?

### When to add a new controller

A controller is the policy layer that mints names and orchestrates the side effects of a registration. Add one when the issuance policy genuinely differs from every existing controller. Different authorisation, a different pricing or eligibility rule, a different set of records to write, or a different cross-contract coordination requirement all count. Do not add one when the difference is a flag on an existing flow; a flag means the existing controller grows a second reason to change, which is what the split is meant to prevent.

A new controller lives behind its own UUPS proxy with its own storage, and is registered on the registrar through `addController`. It must not import any other controller. Cross-flow collisions between controllers are arbitrated at the layers beneath them: ERC721 uniqueness on the registrar, and shared authority contracts like PopRules that both flows read through. Extending this means the new controller needs to think about which cross-flow authorities it writes to and how it keeps its local state in lockstep with them.

### When to add a new resolver

A resolver is the storage layer for per-name records. Add one when a new record category exists that is semantically unrelated to what existing resolvers hold and that has its own authorisation model. An ECDH chat key is a different category from a contenthash, which is a different category from a forward address record; each lives on its own resolver because each has its own writer policy and its own read consumers.

Do not add a resolver for a record that already fits one of the existing categories; extend the existing resolver instead. And do not put user records on the Store: the Store is labels only, by invariant, and every other per-name category goes to a dedicated resolver. A resolver must not hold registration records, and the Store must not hold anything but registration records. Keeping that boundary sharp is what makes the system legible.

Every resolver must spell out its writer policy on its interface and its read surface. Writes are gated; reads are always open. Two gate patterns exist in the system today and picking the right one matters. When the record is owned by the end user, gate on node ownership: the resolver calls back into `DotnsRegistry.owner(node)` on every write, so transferring the name transfers write permission automatically with no resolver upgrade. When the record is owned by a protocol-level writer, gate on the writer address fetched from the protocol registry on every call, so rotating the writer is a single `protocolRegistry.set` call with no resolver upgrade. Do not store the writer address on the resolver itself.

### When to extend something existing instead

Most features fit an existing contract and extending it is the right move. A new text record goes on the content resolver. A new view function on an existing registry adds to that registry. A new validation rule on registration modifies the commit-reveal controller. Adding a new controller or resolver solves a different problem: a responsibility that does not yet have a home. If you cannot cite the new responsibility in a sentence, you are extending, not adding.

Example query paths. Each row starts from a small set of known contracts; every hop is a public view call, so any node can resolve the path without special access.

| Lookup                                    | Path                                                                   |
| ----------------------------------------- | ---------------------------------------------------------------------- |
| Lite labelhash => full-person node        | Protocol registry => PoP resolver => `fullClaim(liteLabelhash)`        |
| Full-person node => lite labelhash        | Protocol registry => PoP resolver => `liteLink(fullNode)`              |
| Node => chat key                          | Protocol registry => PoP resolver => `chatKey(node)`                   |
| Node or tokenId => registered label       | Protocol registry => registrar => `labelOf(uint256(node))`             |
| Base stem => gateway-reservation state    | Protocol registry => PoP controller => `isReservedForClaim(baseLabel)` |
| Base stem => cross-flow reservation state | Protocol registry => PopRules => `isBaseNameReserved(baseLabel)`       |
| Node => ERC721 owner                      | Protocol registry => registrar => `ownerOf(uint256(node))`             |
| Subnode => forward-registry owner         | Protocol registry => registry => `owner(subnode)`                      |
| Node => forward address record            | Protocol registry => forward resolver => address record                |
| Address => primary name                   | Protocol registry => reverse resolver => primary name                  |

### New addresses go through the protocol registry

Any new contract address that other contracts need to read must be looked up through `DotnsProtocolRegistry` at the point of use. Do not hardcode it in a constructor, store it in an `immutable`, or expose a one-off `setX(address)` setter. The protocol registry is the only address a contract may hold directly; everything else is fetched on demand so rotation is a single `protocolRegistry.set(KEY, newAddress)` call with no upgrade.

If you are adding a new contract category, add a `bytes32` key for it in `DotnsConstants.sol`, wire it up in `WireDeployments.s.sol`, and list the contract and its interface in `.github/abi-contracts.txt` so their ABIs ship in the release artifact. Read it the same way every existing contract does.

Bad — the registrar address is frozen at construction, so rotating it needs an upgrade:

```solidity
contract MyResolver {
  address public immutable registrar;

  constructor(address _registrar) {
    registrar = _registrar;
  }

  function _someWrite() internal view {
    require(msg.sender == registrar, "not registrar");
  }
}
```

Good — fetched from the protocol registry on every call, so rotation is one `set`:

```solidity
contract MyResolver {
  IDotnsProtocolRegistry public immutable protocolRegistry;

  constructor(IDotnsProtocolRegistry _protocolRegistry) {
    protocolRegistry = _protocolRegistry;
  }

  function _someWrite() internal view {
    require(
      msg.sender == protocolRegistry.get(DotnsConstants.REGISTRAR),
      "not registrar"
    );
  }
}
```

### Updating an existing contract to consume a new address

When a new contract is added, existing contracts that already read through the protocol registry need no work. A new `bytes32` key in `DotnsConstants.sol` plus a new `protocolRegistry.set(NEW_KEY, addr)` line in `WireDeployments.s.sol` is enough; every other contract picks it up automatically.

An existing contract only needs an upgrade when it must _call_ the new contract. The upgrade is small: add the consumer call site and read the address from the protocol registry at the point of use. Ship it as a normal proxy upgrade with the `Old.sol` snapshot and the cleanup checklist below.

Example. A new `ScoreResolver` is added and `MyResolver` should check the caller's score on writes. The upgrade adds one `.get(...)` lookup, no storage moves, so the `Old.sol` diff is trivial:

```solidity
function _someWrite() internal view {
  require(
    msg.sender == protocolRegistry.get(DotnsConstants.REGISTRAR),
    "not registrar"
  );

  // New consumer call site introduced by the upgrade.
  uint256 score = IScoreResolver(
    protocolRegistry.get(DotnsConstants.SCORE_RESOLVER)
  ).scoreOf(msg.sender);
  require(score >= MIN_SCORE, "insufficient score");
}
```

Do not cache the new address in storage on the existing contract during the upgrade. Caching it locally is what forces the next rotation into a second upgrade PR; reading from the protocol registry on every call keeps future rotations to a single `set`.

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

### Local commit checks

The repository ships a pre-commit hook under `.githooks/pre-commit`. `setup.bash`
installs it by setting `core.hooksPath=.githooks`.

The hook validates repository files, including `.github`, while ignoring external
dependencies under `lib/` and `node_modules/`. It checks structured
configuration and script files such as YAML, JSON, TOML, shell, Python,
JavaScript, `.env.example`, and `.gitmodules`; if `actionlint` is installed, it
also validates GitHub Actions workflow semantics. It then runs `forge fmt`. If
formatting changes any tracked project file, the commit stops so the formatted
files can be reviewed and staged. Finally it runs `forge build` and fails on
compiler warnings from project code. Warnings from external dependencies under
`lib/` and `node_modules/` are ignored.

To install the hook manually:

```bash
git config core.hooksPath .githooks
```

## Upgrade-PR workflow

The conventions below apply specifically to PRs that upgrade an already-deployed proxy. They are scoped to the lifetime of the PR and must be removed before merge; the cleanup checklist at the end of this section is the gate reviewers enforce.

### Storage-collision checks

**Storage-layout safety is non-negotiable on every deploy and upgrade path.** The OpenZeppelin validator runs end-to-end on every proxy: on upgrades it diffs the new implementation's storage layout against a pinned `Old.sol` reference snapshot and fails the build if a slot moves, shrinks, or changes type; on fresh deploys it catches unsafe-upgrade-incompatible patterns (constructors, state-variable assignments and immutables in the implementation, `selfdestruct`, raw `delegatecall`, external library linking, missing initialisers, and so on) that would only surface as a bug the first time a future upgrade is attempted. **No deploy or upgrade script in this repository passes `unsafeSkipAllChecks` or any `unsafeAllow` override, and adding one is not on the table. If validation fails, fix the contract, not the script.**

The validator accepts the predecessor either as a compilable artefact in the same project (for example a `FooOld.sol` sibling) or as a stored `referenceBuildInfoDir`. We have chosen the source-file route deliberately: the snapshot is versioned alongside the implementation, reviewable in a diff, and available to `forge build` without any out-of-band fetch. A stored build-info directory would drift out of lockstep with the code reviewers read.

### The `Old.sol` snapshot convention

The `Old.sol` convention has a fixed shape. For a contract `Foo.sol` declaring `contract Foo is ...`, the snapshot file is `FooOld.sol` in the same directory, declaring `contract FooOld is ...` with the pre-upgrade storage layout, imports, inheritance list, and public surface copied verbatim at the moment the upgrade PR is opened. The only mechanical difference is the `Old` suffix on the file name, the contract name, and any sibling interface the snapshot depends on (for example `IFoo.sol` becomes `IFooOld.sol`). Upgrade scripts reference the snapshot through `Options({referenceContract: "FooOld.sol:FooOld"})` on the matching `Upgrades.upgradeProxy` call.

**`Old.sol` snapshots are PR-scoped and must never land on `master`.** They exist only for the upgrade PR that introduces them, so CI and local `forge build` can diff the new layout against the pre-upgrade layout. **Before the PR merges, every `Old.sol` (and every matching `I*Old.sol`) must be deleted, along with the `referenceContract` wiring in the upgrade script.** Once the upgrade is live, the "old" layout is the on-chain deployment, not a file in the repository; keeping the snapshot around after merge would create a phantom contract that future diffs would treat as real code. Reviewers should refuse any PR that ships `Old.sol` files to `master`.

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
