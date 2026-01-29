#![cfg_attr(not(feature = "std"), no_std, no_main)]

#[cfg(test)]
pub mod test_modules;

pub mod base_store_factory;

#[ink::contract]
pub mod dotns_store_factory {
    use crate::base_store_factory::{BaseStoreFactory, FactoryError};
    use dotns_store::dotns_store::StoreRef;
    use ink::env::call::{build_create, ExecutionInput, Selector};
    use ink::env::hash::Blake2x256;
    use ink::prelude::vec::Vec;
    use ink::primitives::{H160, H256};
    use ink::storage::Mapping;

    /// Emitted when a store is successfully deployed.
    ///
    /// # Topics
    /// - `owner`: The address that deployed and owns the store registry entry.
    /// - `store`: The address of the newly deployed store contract.
    #[ink(event)]
    pub struct StoreDeployed {
        #[ink(topic)]
        pub owner: H160,
        #[ink(topic)]
        pub store: H160,
    }

    /// Emitted when a store has been transferred to a new owner in the factory registry.
    ///
    /// # Topics
    /// - `old_owner`: The address which owned the store registry entry.
    /// - `new_owner`: The address which owns the store registry entry.
    #[ink(event)]
    pub struct OwnershipTransfered {
        #[ink(topic)]
        pub old_owner: H160,
        #[ink(topic)]
        pub new_owner: H160,
    }

    /// Factory contract for deploying and tracking user-specific store instances.
    ///
    /// Uses contract instantiation to deploy a Store. Each address can deploy exactly one store.
    #[ink(storage)]
    pub struct StoreFactory {
        /// Maps owner addresses to their deployed store contracts.
        ///
        /// Missing entry indicates no store has been deployed for that address.
        deployed_stores: Mapping<H160, H160>,

        /// The code hash of the uploaded Store contract to instantiate.
        store_code_hash: H256,

        /// All stores deployed by this factory.
        stores: Vec<H160>,
    }

    impl StoreFactory {
        /// Creates a new StoreFactory.
        ///
        /// # Arguments
        /// - `store_code_hash`: The uploaded code hash of the Store contract.
        ///
        /// # Returns
        /// - A new `StoreFactory` instance with an empty registry.
        #[ink(constructor)]
        pub fn new(store_code_hash: H256) -> Self {
            Self {
                deployed_stores: Mapping::default(),
                store_code_hash,
                stores: Vec::new(),
            }
        }

        /// Returns the configured Store code hash used for instantiation.
        ///
        /// # Returns
        /// - The current store code hash.
        #[ink(message)]
        pub fn store_code_hash(&self) -> H256 {
            self.store_code_hash
        }

        fn has_store(&self, who: &H160) -> bool {
            self.deployed_stores.get(who).is_some()
        }
    }

    impl BaseStoreFactory for StoreFactory {
        #[ink(message)]
        fn deploy(&mut self) -> Result<H160, FactoryError> {
            let caller = self.env().caller();

            if let Some(existing) = self.deployed_stores.get(&caller) {
                return Err(FactoryError::AlreadyDeployed(existing));
            }

            let mut salt = [0u8; 32];
            let block_number = self.env().block_number();
            ink::env::hash_encoded::<Blake2x256, _>(&(caller, block_number), &mut salt);

            let create_params = build_create::<StoreRef>()
                .code_hash(self.store_code_hash)
                .endowment(0.into())
                .exec_input(ExecutionInput::new(Selector::new(ink::selector_bytes!(
                    "new"
                ))))
                .salt_bytes(Some(salt))
                .returns::<StoreRef>()
                .params();

            let store_ref = self
                .env()
                .instantiate_contract(&create_params)
                .map_err(|_| FactoryError::DeploymentFailed)?
                .map_err(|_| FactoryError::DeploymentFailed)?;

            use ink::ToAddr;
            let store_addr: H160 = store_ref.to_addr();

            let reported_owner = store_ref.owner();
            if reported_owner != caller {
                // We dont use require! here given the circular
                // dependency with the utils crate
                return Err(FactoryError::InvalidOwnership(store_addr));
            }

            self.deployed_stores.insert(caller, &store_addr);
            self.stores.push(store_addr);

            self.env().emit_event(StoreDeployed {
                owner: caller,
                store: store_addr,
            });

            Ok(store_addr)
        }

        #[ink(message)]
        fn transfer_ownership(&mut self, new_owner: H160) -> Result<(), FactoryError> {
            let caller = self.env().caller();

            let store = self
                .deployed_stores
                .get(&caller)
                .ok_or(FactoryError::InvalidTransfer(caller))?;

            if new_owner != H160::zero() && self.has_store(&new_owner) {
                // We dont use require! here given the circular
                // dependency with the utils crate
                return Err(FactoryError::InvalidTransfer(new_owner));
            }

            self.env().emit_event(OwnershipTransfered {
                old_owner: caller,
                new_owner,
            });

            self.deployed_stores.remove(&caller);
            self.deployed_stores.insert(new_owner, &store);

            Ok(())
        }

        #[ink(message)]
        fn get_deployed_store(&self, who: H160) -> H160 {
            self.deployed_stores.get(&who).unwrap_or(H160::zero())
        }

        #[ink(message)]
        fn deployed_stores(&self) -> Vec<H160> {
            self.stores.clone()
        }
    }
}
