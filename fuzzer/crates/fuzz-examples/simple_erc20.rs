use ink::storage::Mapping;

#[ink::contract]
pub mod simple_erc20 {
    use super::*;
    use ink::{prelude::string::String, H160};

    /// Minimal token with mint (owner only) + transfer.
    /// Messages return `bool` so we do not need custom SCALE/TypeInfo errors.
    #[ink(storage)]
    pub struct SimpleErc20 {
        owner: H160,
        total_supply: Balance,
        balances: Mapping<H160, Balance>,
        name: String,
        symbol: String,
        decimals: u8,
    }

    impl SimpleErc20 {
        #[ink(constructor)]
        pub fn new(name: String, symbol: String, decimals: u8) -> Self {
            let owner = Self::env().caller();
            Self {
                owner,
                total_supply: 0,
                balances: Mapping::default(),
                name,
                symbol,
                decimals,
            }
        }

        #[ink(message)]
        pub fn owner(&self) -> H160 {
            self.owner
        }

        #[ink(message)]
        pub fn total_supply(&self) -> Balance {
            self.total_supply
        }

        #[ink(message)]
        pub fn balance_of(&self, account: H160) -> Balance {
            self.balances.get(account).unwrap_or(0)
        }

        #[ink(message)]
        pub fn name(&self) -> String {
            self.name.clone()
        }

        #[ink(message)]
        pub fn symbol(&self) -> String {
            self.symbol.clone()
        }

        #[ink(message)]
        pub fn decimals(&self) -> u8 {
            self.decimals
        }

        /// Returns false if caller is not owner.
        #[ink(message)]
        pub fn mint(&mut self, to: H160, amount: Balance) -> bool {
            if self.env().caller() != self.owner {
                return false;
            }

            let current = self.balance_of(to);
            let next = current.saturating_add(amount);
            self.balances.insert(to, &next);

            self.total_supply = self.total_supply.saturating_add(amount);
            true
        }

        /// Returns false if insufficient balance.
        #[ink(message)]
        pub fn transfer(&mut self, to: H160, amount: Balance) -> bool {
            let from = self.env().caller();
            let from_balance = self.balance_of(from);

            if from_balance < amount {
                return false;
            }

            let to_balance = self.balance_of(to);

            let new_from = from_balance - amount;
            let new_to = to_balance.saturating_add(amount);

            self.balances.insert(from, &new_from);
            self.balances.insert(to, &new_to);

            true
        }
    }
}
