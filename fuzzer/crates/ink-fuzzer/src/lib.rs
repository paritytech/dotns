//! ink-fuzzer
//!
//! Fuzz testing helpers for ink! v6 contracts using `proptest` under the hood.
//!
//! What this crate provides
//!
//! - `#[ink_fuzzer::fuzz]` attribute macro for fuzz tests.
//! - `Context` type for generating and applying ink off-chain environment parameters.
//! - A stable runner function is generated per fuzz test: `run_<test_name>()`.
//!
//! What “fuzzing” means here
//!
//! This is off-chain fuzzing, similar to how Foundry tests execute off-chain but simulate
//! on-chain interactions. Each fuzz case runs inside ink's off-chain test environment via
//! `ink::env::test::run_test::<DefaultEnvironment, _>(...)`.
//!
//! This does not execute Wasm in a node runtime. It exercises the Rust contract code with
//! ink's test environment APIs.
//!
//! Basic usage
//!
//! Create a file under `tests/`, then write a fuzz harness:
//!
//! ```rust,ignore
//! use ink_fuzzer::{fuzz, Context};
//!
//! // Replace this import with your contract type.
//! // use my_contract::MyContract;
//!
//! #[fuzz(cases = 256)]
//! fn flips_preserve_parity(context: Context, initial: bool, flip_count: u8) {
//!     // Optional: apply generated environment changes.
//!     context.apply();
//!
//!     // Example logic (replace with your contract calls).
//!     let mut value = initial;
//!     for _ in 0..flip_count {
//!         value = !value;
//!     }
//!
//!     let expected = if flip_count % 2 == 0 { initial } else { !initial };
//!     assert_eq!(value, expected);
//! }
//! ```
//!
//! Generated symbols
//!
//! For a fuzz harness named `my_test`, the macro expands into:
//!
//! - `fn __ink_fuzzer_internal_my_test(...) { ... }`
//!   Internal helper that contains the original user code.
//!
//! - `fn my_test(...)`
//!   The `proptest` wrapper annotated with `#[proptest::property_test]`.
//!   The test harness executes this wrapper.
//!
//! - `fn run_my_test()`
//!   A no-argument helper that calls the wrapper. This is useful when you want to run
//!   the fuzz campaign from another `#[test]` while keeping control over ordering or
//!   counters.
//!
//! `Context`
//!
//! `Context` is `Arbitrary` (via `proptest`) and can be used as a fuzz parameter.
//! Call `Context::apply()` inside the harness to set ink off-chain environment values
//! such as caller/callee/value/block parameters for that case.
//!
//! Configuration
//!
//! `#[fuzz(cases = N)]` sets the number of generated cases. If omitted, defaults to 256.
//!
//! Limitations
//!
//! - The macro supports only free functions (no `self` receiver).
//! - Function parameters must be simple identifiers (e.g. `x: u32`), not destructuring.
//! - Async functions are not supported.
//!
//! Re-exports
//!
//! This crate re-exports `proptest` as `ink_fuzzer::proptest` so the proc-macro can refer
//! to it via an absolute path and consumers do not need a direct `proptest` dependency.

pub use ink_fuzzer_macros::fuzz;
pub use proptest;

mod context;
pub mod prelude;

pub use context::Context;
