# Contribution Guidelines

These guidelines apply to the DotNS repository ("dotns"). Contributions are welcome via issues, pull requests, reviews, and testing feedback.

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

## Code of conduct

Be respectful and constructive.

- Harassment, abuse, or aggressive behaviour is not acceptable.
- Spam issues/PRs, or contributions unrelated to DotNS, may be closed.
