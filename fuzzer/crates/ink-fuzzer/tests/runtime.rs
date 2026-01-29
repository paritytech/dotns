use std::collections::HashMap;
use std::sync::{Mutex, Once, OnceLock};

use ink::primitives::Address;
use ink_fuzzer::{fuzz, Context};

/// Stores per-test invocation counts.
/// Mutex is required because tests can run in parallel.
static INVOCATION_COUNTS: OnceLock<Mutex<HashMap<&'static str, usize>>> = OnceLock::new();

fn invocation_counts() -> &'static Mutex<HashMap<&'static str, usize>> {
    INVOCATION_COUNTS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn set_invocation_count(test_name: &'static str, value: usize) {
    let mut locked_counts = invocation_counts().lock().unwrap();
    locked_counts.insert(test_name, value);
}

fn increment_invocation_count(test_name: &'static str) -> usize {
    let mut locked_counts = invocation_counts().lock().unwrap();
    let entry = locked_counts.entry(test_name).or_insert(0);
    *entry += 1;
    *entry
}

#[ink::contract]
mod dummy_contract {
    #[ink(storage)]
    pub struct DummyContract {
        upset: bool,
    }

    impl DummyContract {
        #[ink(constructor)]
        pub fn new(upset: bool) -> Self {
            Self { upset }
        }

        #[ink(message)]
        pub fn flip(&mut self) {
            self.upset = !self.upset;
        }

        #[ink(message)]
        pub fn get(&self) -> bool {
            self.upset
        }
    }
}

use dummy_contract::DummyContract;

/// This fuzz test validates that `cases = 16` is applied by asserting:
/// - the function is never invoked more than 16 times in a single run.
/// The count is reset once per test run using `Once`.
#[fuzz(cases = 16)]
fn macro_runs_16_cases(initial: bool) {
    static INITIALIZE_COUNTER: Once = Once::new();
    INITIALIZE_COUNTER.call_once(|| set_invocation_count("macro_runs_16_cases", 0));

    let current_case_index = increment_invocation_count("macro_runs_16_cases");
    assert!(
        current_case_index <= 16,
        "expected at most 16 cases, observed {}",
        current_case_index
    );

    let mut contract = DummyContract::new(initial);
    contract.flip();
    assert_eq!(contract.get(), !initial);
}

/// This fuzz test validates `cases = 8` and verifies `Context::apply()` works.
/// It asserts:
/// - the function is never invoked more than 8 times in a single run.
/// - `ink::env::caller()` matches the value applied by `Context`.
#[fuzz(cases = 8)]
fn context_apply_sets_caller(context: Context, _unused: u8) {
    static INITIALIZE_COUNTER: Once = Once::new();
    INITIALIZE_COUNTER.call_once(|| set_invocation_count("context_apply_sets_caller", 0));

    let current_case_index = increment_invocation_count("context_apply_sets_caller");
    assert!(
        current_case_index <= 8,
        "expected at most 8 cases, observed {}",
        current_case_index
    );

    let expected_caller = Address::from([7u8; 20]);

    let mut mutable_context = context;
    mutable_context.caller = expected_caller;
    mutable_context.apply();

    assert_eq!(ink::env::caller(), expected_caller);
}
