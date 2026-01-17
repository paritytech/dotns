# ink-fuzzer

`ink-fuzzer` is a small testing crate for ink! v6 that makes it easy to write property-based fuzz tests inside ordinary `#[ink::test]` unit tests.

The intent is practical. Smart-contract bugs often live in corners: input validation, boundary conditions, and state transitions that only show up after a few calls. Fuzzing is a way to spend compute to explore those corners. It improves coverage and reduces regressions. It does not turn a contract into a proven system.

This crate is designed to feel normal in Rust. You write invariants as code, and the runner searches for counterexamples, shrinking inputs when it finds one.

## What it is

- A thin wrapper around property-based testing to support fuzz-style tests in ink! unit tests.
- A macro-based API so fuzz tests read like regular Rust tests.
- A place to encode invariants as executable checks.

## What it is not

- Not a security proof.
- Not an on-chain fuzzer.
- Not a model checker.
- Not a substitute for audits, review, or a threat model.

Fuzzing explores an input space. It cannot guarantee it explored the part of the space that matters for your protocol.

## Why this exists

In Solidity land, fuzzing became “default” partly because it was cheap to use: write a test with parameters, run it, get lots of cases and shrinking. This changes developer behavior because invariants become easy to express and easy to keep running.

ink! development is moving quickly, but fuzzing ergonomics are still uneven. The goal here is to lower the friction so writing invariants as tests becomes routine.

## Status and roadmap

This is aimed at stateless fuzzing over message inputs inside `#[ink::test]` workflows.

A natural next step is stateful fuzzing: generating sequences of calls and checking invariants across evolving contract state. The plan is to add this later. It is not part of the current design.

## Installation

Add `ink-fuzzer` as a dev-dependency in your ink! contract crate.

```toml
[dev-dependencies]
ink-fuzzer = { path = "../path/to/ink-fuzzer" }
````

## Usage

The `#[fuzz]` attribute generates a property-based test that runs inside the ink! test environment. You can accept ordinary Rust parameters (integers, bools, byte vectors) and use them to drive calls into your contract.

Most fuzz tests need a consistent way to:

* create a contract instance
* set up the ink! test environment (caller, transferred value, timestamp)

Below is a minimal setup pattern. The contract type and method names are placeholders.

```rust
use ink::H160;
use ink_fuzzer::{fuzz, Context};

fn default_accounts() -> ink::env::test::DefaultAccounts {
    ink::env::test::default_accounts()
}

fn set_environment_caller(caller: H160) {
    ink::env::test::set_caller(caller);
}

fn set_environment_block_timestamp(timestamp: u64) {
    ink::env::test::set_block_timestamp::<ink::env::DefaultEnvironment>(timestamp);
}

fn make_contract() -> ExampleContract {
    let accounts = default_accounts();
    set_environment_caller(accounts.alice);
    ExampleContract::new()
}
```

### Example: an invariant over many inputs

A typical pattern is:

1. generate inputs
2. call into the contract
3. assert the invariant

```rust
use ink_fuzzer::{fuzz, Context};

#[fuzz(cases = 512)]
fn fuzz_example_invariant(context: Context, input_a: u128, input_b: u128) {
    context.apply();

    let mut contract = make_contract();

    // Drive contract behavior with fuzz inputs (replace with your methods).
    contract.do_something(input_a);
    contract.do_something_else(input_b);

    // Invariant: something that should always hold.
    let state = contract.read_state();
    assert!(state.some_value <= state.some_limit);
}
```

### Notes

* Prefer invariants that are cheap to evaluate and meaningful for security and correctness.
* Avoid panics by construction. If you slice strings or vectors, normalize lengths first.
* If an invariant is supposed to reject an input, assert on the error path explicitly.
* Shrinking matters. It is often the difference between “a failure happened” and “a failure you can understand”.

````md
## Running tests

Run your contract tests as usual:

```sh
cargo test
````

If you maintain a separate examples crate, run it the same way:

```sh
cargo test -p fuzz-examples
```

To run a specific example inside `fuzz-examples`, select it with feature flags:

```sh
# Flipper (default)
cargo test -p fuzz-examples

# ERC20 example
cargo test -p fuzz-examples --no-default-features --features example-erc20
```

Feature flags are required because `#[ink::contract]` emits a `__ink_generate_metadata` symbol. If you compile two `#[ink::contract]` modules into the same crate, the linker sees the symbol twice and fails. Building only one example at a time via features avoids the collision.

# Future work

### Stateful fuzzing

- Generate sequences of contract calls rather than single-call properties.
- Check invariants after every step, not only at the end.
- Support multiple callers, value transfers, timestamps, and block progression as part of the generated state.

### Shrinking for sequences

- When a failure happens in a long call sequence, shrink the sequence length and the arguments to a minimal reproducer.

### First-class environment modeling

- Better helpers for caller rotation, timestamp/block number stepping, transferred value, and contract balance.
- Safer defaults so "empty input" and "short input" do not cause panics in test helpers.

### Cross-contract and multi-instance scenarios

- Fuzz interactions between two deployed contracts in the same test.
- Support multiple instances of the same contract to test isolation and shared assumptions.

### Coverage and reproducibility tooling

- Seed capture and replay helpers (print failing seeds, rerun a specific failing case).
- Optional coverage guidance so test authors can see which branches are not being exercised.


## License
MIT 
