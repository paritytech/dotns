use ink::primitives::{Address, U256};

/// A minimal “transaction-ish” context for fuzzing ink! off-chain tests.
///
/// This maps cleanly to the ink v6 off-chain test APIs:
/// - set_caller(Address)
/// - set_callee(Address)
/// - set_value_transferred(U256)
/// - set_block_number::<DefaultEnvironment>(u32)
/// - set_block_timestamp::<DefaultEnvironment>(u64)
#[derive(Clone, Debug)]
pub struct Context {
    pub caller: Address,
    pub callee: Address,
    pub value_transferred: U256,
    pub contract_balance: Option<U256>,
    pub block_number: u32,
    pub block_timestamp: u64,
}

impl Default for Context {
    fn default() -> Self {
        Self {
            caller: Address::from([0u8; 20]),
            callee: Address::from([0u8; 20]),
            value_transferred: U256::zero(),
            contract_balance: None,
            block_number: 0,
            block_timestamp: 0,
        }
    }
}

impl Context {
    /// Applies the context to the current ink off-chain test environment.
    ///
    /// This is only meaningful inside `ink::env::test::run_test(...)`.
    #[cfg(feature = "std")]
    pub fn apply(&self) {
        use ink::env::test;

        test::set_caller(self.caller);
        test::set_callee(self.callee);
        test::set_value_transferred(self.value_transferred);

        test::set_block_number::<ink::env::DefaultEnvironment>(self.block_number);
        test::set_block_timestamp::<ink::env::DefaultEnvironment>(self.block_timestamp);

        if let Some(bal) = self.contract_balance {
            // This may panic if the addr does not exist in the off-chain env.
            // If you want it always safe, wrap it in a “known address” policy.
            test::set_contract_balance(self.callee, bal);
        }
    }
}

#[cfg(feature = "std")]
impl proptest::arbitrary::Arbitrary for Context {
    type Parameters = ();
    type Strategy = proptest::strategy::BoxedStrategy<Self>;

    fn arbitrary_with(_: Self::Parameters) -> Self::Strategy {
        use proptest::prelude::*;

        (
            any::<[u8; 20]>(),
            any::<[u8; 20]>(),
            any::<[u8; 32]>(),
            proptest::option::of(any::<[u8; 32]>()),
            any::<u32>(),
            any::<u64>(),
        )
            .prop_map(
                |(caller_b, callee_b, value_b, bal_b, block_number, block_timestamp)| {
                    let caller = Address::from(caller_b);
                    let callee = Address::from(callee_b);
                    let value_transferred = U256::from_big_endian(&value_b);
                    let contract_balance = bal_b.map(|bb| U256::from_big_endian(&bb));
                    Context {
                        caller,
                        callee,
                        value_transferred,
                        contract_balance,
                        block_number,
                        block_timestamp,
                    }
                },
            )
            .boxed()
    }
}
