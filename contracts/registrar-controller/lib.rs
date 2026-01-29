#![cfg_attr(not(feature = "std"), no_std, no_main)]

#[cfg(test)]
pub mod test_modules;

pub mod registrar_controller;

#[ink::contract]
pub mod dotns_registrar_controller {
    use crate::registrar_controller::{
        BaseDotnsRegistrarController, RegistrarControllerError, Registration,
    };
    use dotns_pop_rules::base_pop_rules::{BaseDotnsPopRules, PopStatus};
    use dotns_pop_rules::DotnsPopRulesRef;
    use dotns_registrar::registrar::BaseDotnsRegistrar;
    use dotns_registrar::DotnsRegistrarRef;
    use dotns_registry::registry::BaseDotnsRegistry;
    use dotns_registry::DotnsRegistryRef;
    use dotns_reverse_resolver::reverse_resolver::BaseDotnsReverseResolver;
    use dotns_reverse_resolver::DotnsReverseResolverRef;
    use dotns_store::store_base::StoreBase;
    use dotns_store::StoreRef;
    use dotns_store_factory::StoreFactoryRef;
    use dotns_utils::store::store_utils;
    use dotns_utils::{require, DOTNS_REGISTERED_KEY, DOT_NODE};
    use ink::env::call::FromAddr;
    use ink::env::hash::{HashOutput, Keccak256};
    use ink::prelude::string::String;
    use ink::prelude::vec::Vec;
    use ink::primitives::{H160, H256, U256};
    use ink::storage::Mapping;
    use ink::ToAddr;

    /// Upper bound for commitment validity to cap storage griefing risk (7 days in seconds).
    const MAX_ALLOWED_COMMITMENT_AGE: u64 = 7 * 24 * 60 * 60;

    /// Emitted when a commitment is submitted.
    #[ink(event)]
    pub struct NameCommitted {
        /// The commitment hash that was submitted.
        #[ink(topic)]
        pub commitment: H256,
    }

    /// Emitted when a name is successfully registered.
    #[ink(event)]
    pub struct NameRegistered {
        /// The human-readable label that was registered.
        #[ink(topic)]
        pub label: String,
        /// The keccak256 hash of the label.
        #[ink(topic)]
        pub labelhash: H256,
        /// The address that owns the registered name.
        #[ink(topic)]
        pub owner: H160,
        /// The base cost paid for registration.
        pub base_cost: u128,
        /// The Store contract address for the owner.
        pub store: H160,
    }

    /// DotNS Registrar Controller Contract
    ///
    /// Manages the registration flow for .dot names including commitment-reveal
    /// scheme to prevent front-running, price validation via PoP rules, and
    /// automatic Store deployment for new registrants.
    #[ink(storage)]
    pub struct DotnsRegistrarController {
        /// The contract owner with administrative privileges.
        owner: H160,
        /// Reference to the DotNS Registrar contract for token minting.
        dotns_registrar: DotnsRegistrarRef,
        /// Reference to the DotNS Registry contract for ownership records.
        dotns_registry: DotnsRegistryRef,
        /// Reference to the Reverse Resolver for name-to-address mappings.
        reverse_resolver: DotnsReverseResolverRef,
        /// Reference to the PoP Rules contract for pricing validation.
        pop_rules: DotnsPopRulesRef,
        /// Reference to the Store Factory for deploying user stores.
        store_factory: StoreFactoryRef,
        /// Minimum age in seconds before a commitment can be revealed.
        min_commitment_age: u64,
        /// Maximum age in seconds after which a commitment expires.
        max_commitment_age: u64,
        /// Mapping from commitment hash to timestamp when it was submitted.
        commitments: Mapping<H256, u64>,
    }

    impl DotnsRegistrarController {
        /// Creates a new Registrar Controller contract.
        ///
        /// # Arguments
        ///
        /// * `registrar` - Reference to the DotNS Registrar contract.
        /// * `registry` - Reference to the DotNS Registry contract.
        /// * `reverse` - Reference to the Reverse Resolver contract.
        /// * `rules` - Reference to the PoP Rules contract.
        /// * `factory` - Reference to the Store Factory contract.
        /// * `min_age` - Minimum commitment age in seconds.
        /// * `max_age` - Maximum commitment age in seconds.
        ///
        /// # Errors
        ///
        /// * `MaxCommitmentAgeTooLow` - If max_age is not greater than min_age.
        /// * `MaxCommitmentAgeTooHigh` - If max_age exceeds the allowed maximum.
        #[ink(constructor)]
        pub fn new(
            registrar: DotnsRegistrarRef,
            registry: DotnsRegistryRef,
            reverse: DotnsReverseResolverRef,
            rules: DotnsPopRulesRef,
            factory: StoreFactoryRef,
            min_age: u64,
            max_age: u64,
        ) -> Result<Self, RegistrarControllerError> {
            require!(
                max_age > min_age,
                RegistrarControllerError::MaxCommitmentAgeTooLow
            );
            require!(
                max_age <= MAX_ALLOWED_COMMITMENT_AGE,
                RegistrarControllerError::MaxCommitmentAgeTooHigh
            );

            let caller = Self::env().caller();
            Ok(Self {
                owner: caller,
                dotns_registrar: registrar,
                dotns_registry: registry,
                reverse_resolver: reverse,
                pop_rules: rules,
                store_factory: factory,
                min_commitment_age: min_age,
                max_commitment_age: max_age,
                commitments: Mapping::default(),
            })
        }

        /// Returns the contract owner.
        ///
        /// # Returns
        ///
        /// The H160 address of the contract owner.
        #[ink(message)]
        pub fn owner(&self) -> H160 {
            self.owner
        }

        /// Returns the base registrar address.
        ///
        /// # Returns
        ///
        /// The H160 address of the DotNS Registrar contract.
        #[ink(message)]
        pub fn dotns_registrar(&self) -> H160 {
            self.dotns_registrar.to_addr()
        }

        /// Returns the registry address.
        ///
        /// # Returns
        ///
        /// The H160 address of the DotNS Registry contract.
        #[ink(message)]
        pub fn dotns_registry(&self) -> H160 {
            self.dotns_registry.to_addr()
        }

        /// Returns the reverse resolver address.
        ///
        /// # Returns
        ///
        /// The H160 address of the Reverse Resolver contract.
        #[ink(message)]
        pub fn reverse_resolver(&self) -> H160 {
            self.reverse_resolver.to_addr()
        }

        /// Returns the PoP rules address.
        ///
        /// # Returns
        ///
        /// The H160 address of the PoP Rules contract.
        #[ink(message)]
        pub fn pop_rules(&self) -> H160 {
            self.pop_rules.to_addr()
        }

        /// Returns the store factory address.
        ///
        /// # Returns
        ///
        /// The H160 address of the Store Factory contract.
        #[ink(message)]
        pub fn store_factory(&self) -> H160 {
            self.store_factory.to_addr()
        }

        /// Returns the minimum commitment age.
        ///
        /// # Returns
        ///
        /// The minimum age in seconds before a commitment can be revealed.
        #[ink(message)]
        pub fn min_commitment_age(&self) -> u64 {
            self.min_commitment_age
        }

        /// Returns the maximum commitment age.
        ///
        /// # Returns
        ///
        /// The maximum age in seconds after which a commitment expires.
        #[ink(message)]
        pub fn max_commitment_age(&self) -> u64 {
            self.max_commitment_age
        }

        /// Returns the timestamp of a commitment.
        ///
        /// # Arguments
        ///
        /// * `commitment` - The commitment hash to look up.
        ///
        /// # Returns
        ///
        /// The Unix timestamp when the commitment was submitted, or 0 if not found.
        #[ink(message)]
        pub fn commitment_timestamp(&self, commitment: H256) -> u64 {
            self.commitments.get(commitment).unwrap_or(0)
        }

        /// Returns the implementation version.
        ///
        /// # Returns
        ///
        /// A string representing the contract version.
        #[ink(message)]
        pub fn version(&self) -> String {
            String::from("1.1.0")
        }

        /// Transfers ownership of the contract.
        ///
        /// # Arguments
        ///
        /// * `new_owner` - The address of the new owner.
        ///
        /// # Errors
        ///
        /// * `NotOwner` - If the caller is not the current owner.
        #[ink(message)]
        pub fn transfer_ownership(
            &mut self,
            new_owner: H160,
        ) -> Result<(), RegistrarControllerError> {
            require!(
                self.env().caller() == self.owner,
                RegistrarControllerError::NotOwner
            );
            self.owner = new_owner;
            Ok(())
        }

        /// Computes the keccak256 hash of a label string.
        ///
        /// # Arguments
        ///
        /// * `label` - The label string to hash.
        ///
        /// # Returns
        ///
        /// The H256 keccak256 hash of the label.
        fn labelhash(&self, label: &str) -> H256 {
            let mut output = <Keccak256 as HashOutput>::Type::default();
            ink::env::hash_bytes::<Keccak256>(label.as_bytes(), &mut output);
            H256::from(output)
        }

        /// Computes the namehash for a .dot subdomain.
        ///
        /// Combines the DOT_NODE with the labelhash to produce the full namehash.
        ///
        /// # Arguments
        ///
        /// * `labelhash` - The keccak256 hash of the label.
        ///
        /// # Returns
        ///
        /// The H256 namehash of the full .dot name.
        fn namehash(&self, labelhash: H256) -> H256 {
            let mut data = [0u8; 64];
            data[..32].copy_from_slice(DOT_NODE.as_bytes());
            data[32..].copy_from_slice(labelhash.as_bytes());

            let mut output = <Keccak256 as HashOutput>::Type::default();
            ink::env::hash_bytes::<Keccak256>(&data, &mut output);
            H256::from(output)
        }

        /// Computes the store key for a registered name.
        ///
        /// Combines the DOTNS_REGISTERED_KEY with the labelhash to produce a unique storage key.
        ///
        /// # Arguments
        ///
        /// * `labelhash` - The keccak256 hash of the label.
        ///
        /// # Returns
        ///
        /// A 32-byte array representing the store key.
        fn store_key(&self, labelhash: H256) -> [u8; 32] {
            let mut data = [0u8; 64];
            data[..32].copy_from_slice(DOTNS_REGISTERED_KEY.as_bytes());
            data[32..].copy_from_slice(labelhash.as_bytes());

            let mut output = <Keccak256 as HashOutput>::Type::default();
            ink::env::hash_bytes::<Keccak256>(&data, &mut output);
            output
        }

        /// Returns the character count of a string.
        ///
        /// Uses Unicode character counting, not byte length.
        ///
        /// # Arguments
        ///
        /// * `s` - The string to count characters in.
        ///
        /// # Returns
        ///
        /// The number of Unicode characters in the string.
        fn strlen(&self, s: &str) -> usize {
            s.chars().count()
        }

        /// Constructs the full .dot name from a label.
        ///
        /// # Arguments
        ///
        /// * `label` - The label to append .dot suffix to.
        ///
        /// # Returns
        ///
        /// The full name string with .dot suffix.
        fn full_name(&self, label: &str) -> String {
            let mut name = String::from(label);
            name.push_str(".dot");
            name
        }

        /// Returns this contract's address as H160.
        ///
        /// # Returns
        ///
        /// The H160 address of this contract.
        fn this_contract(&self) -> H160 {
            self.env().address()
        }
    }

    impl BaseDotnsRegistrarController for DotnsRegistrarController {
        #[ink(message)]
        fn available(&self, label: String) -> Result<bool, RegistrarControllerError> {
            require!(
                self.strlen(&label) >= 3,
                RegistrarControllerError::NameNotAvailable { label }
            );

            let labelhash = self.labelhash(&label);
            let token_id = U256::from_big_endian(labelhash.as_bytes());

            Ok(self.dotns_registrar.available(token_id))
        }

        #[ink(message)]
        fn make_commitment(&self, registration: Registration) -> H256 {
            let mut data = Vec::new();
            data.extend_from_slice(registration.label.as_bytes());
            data.extend_from_slice(registration.owner.as_bytes());
            data.extend_from_slice(registration.secret.as_bytes());
            data.push(if registration.reserved { 1 } else { 0 });

            let mut output = <Keccak256 as HashOutput>::Type::default();
            ink::env::hash_bytes::<Keccak256>(&data, &mut output);
            H256::from(output)
        }

        #[ink(message)]
        fn commit(&mut self, commitment: H256) -> Result<(), RegistrarControllerError> {
            let current_time = self.env().block_timestamp();
            let existing = self.commitments.get(commitment).unwrap_or(0);

            require!(
                existing == 0 || existing + self.max_commitment_age < current_time,
                RegistrarControllerError::UnexpiredCommitmentExists { commitment }
            );

            self.commitments.insert(commitment, &current_time);
            self.env().emit_event(NameCommitted { commitment });
            Ok(())
        }

        #[ink(message, payable)]
        fn register(&mut self, registration: Registration) -> Result<(), RegistrarControllerError> {
            let label = registration.label.clone();

            require!(
                self.available(label.clone())?,
                RegistrarControllerError::NameNotAvailable {
                    label: label.clone()
                }
            );

            let labelhash = self.labelhash(&label);
            let commitment = self.make_commitment(registration.clone());
            let committed_at = self.commitments.get(commitment).unwrap_or(0);
            let current_time = self.env().block_timestamp();

            require!(
                committed_at != 0,
                RegistrarControllerError::CommitmentNotFound { commitment }
            );

            let min_time = committed_at + self.min_commitment_age;
            require!(
                min_time <= current_time,
                RegistrarControllerError::CommitmentTooNew {
                    commitment,
                    min_time,
                    current_time
                }
            );

            let max_time = committed_at + self.max_commitment_age;
            require!(
                max_time > current_time,
                RegistrarControllerError::CommitmentTooOld {
                    commitment,
                    max_time,
                    current_time
                }
            );

            self.commitments.remove(commitment);

            let price_meta = self
                .pop_rules
                .price_with_check(label.clone(), registration.owner)
                .map_err(|_| RegistrarControllerError::CallFailed)?;

            let transferred = self.env().transferred_value();
            let price_tag = U256::from(price_meta.price);

            require!(
                transferred >= price_tag,
                RegistrarControllerError::InsufficientValue
            );

            let token_id = U256::from_big_endian(labelhash.as_bytes());
            self.dotns_registrar
                .register(token_id, registration.owner)
                .map_err(|error| RegistrarControllerError::RegistrarCallFailed { error })?;

            let node = self.namehash(labelhash);
            self.dotns_registry
                .set_owner(node, registration.owner, self.reverse_resolver.to_addr())
                .map_err(|_| RegistrarControllerError::CallFailed)?;

            if registration.reserved {
                let full_name = self.full_name(&label);
                self.reverse_resolver
                    .set_reverse_name(registration.owner, full_name)
                    .map_err(|_| RegistrarControllerError::CallFailed)?;
            }

            let controllers: Vec<H160> = vec![self.this_contract(), self.dotns_registry.to_addr()];
            let contract_address = self.this_contract();

            let store_addr = store_utils::get_or_create_store(
                &mut self.store_factory,
                controllers,
                registration.owner,
                contract_address,
            )
            .map_err(|_| RegistrarControllerError::InvalidStore)?;

            let mut store_ref = StoreRef::from_addr(store_addr);
            let store_key = self.store_key(labelhash);
            let full_name = self.full_name(&label);

            store_ref
                .set_value_for(registration.owner, store_key, full_name)
                .map_err(|_| RegistrarControllerError::CallFailed)?;

            self.env().emit_event(NameRegistered {
                label: label.clone(),
                labelhash,
                owner: registration.owner,
                base_cost: price_meta.price,
                store: store_addr,
            });

            if price_meta.status == PopStatus::PopLite
                && price_meta.user_status == PopStatus::PopLite
            {
                let _ = self
                    .pop_rules
                    .reserve_base_name(label.clone(), registration.owner);
            }

            if transferred > price_tag {
                let refund = transferred - price_tag;
                let result = self.env().transfer(self.env().caller(), refund);
                require!(result.is_ok(), RegistrarControllerError::RefundFailed);
            }

            Ok(())
        }

        #[ink(message)]
        fn register_reserved(
            &mut self,
            registration: Registration,
        ) -> Result<(), RegistrarControllerError> {
            require!(
                self.env().caller() == self.owner,
                RegistrarControllerError::NotOwner
            );

            let label = registration.label.clone();

            require!(
                self.available(label.clone())?,
                RegistrarControllerError::NameNotAvailable {
                    label: label.clone()
                }
            );

            let labelhash = self.labelhash(&label);
            let node = self.namehash(labelhash);
            let commitment = self.make_commitment(registration.clone());
            let committed_at = self.commitments.get(commitment).unwrap_or(0);
            let current_time = self.env().block_timestamp();

            require!(
                committed_at != 0,
                RegistrarControllerError::CommitmentNotFound { commitment }
            );

            let min_time = committed_at + self.min_commitment_age;
            require!(
                min_time <= current_time,
                RegistrarControllerError::CommitmentTooNew {
                    commitment,
                    min_time,
                    current_time
                }
            );

            let max_time = committed_at + self.max_commitment_age;
            require!(
                max_time > current_time,
                RegistrarControllerError::CommitmentTooOld {
                    commitment,
                    max_time,
                    current_time
                }
            );

            self.commitments.remove(commitment);

            let token_id = U256::from_big_endian(labelhash.as_bytes());
            self.dotns_registrar
                .register(token_id, registration.owner)
                .map_err(|_| RegistrarControllerError::CallFailed)?;

            self.dotns_registry
                .set_owner(node, registration.owner, self.reverse_resolver.to_addr())
                .map_err(|_| RegistrarControllerError::CallFailed)?;

            let full_name = self.full_name(&label);
            self.reverse_resolver
                .set_reverse_name(registration.owner, full_name.clone())
                .map_err(|_| RegistrarControllerError::CallFailed)?;

            let controllers: Vec<H160> = vec![self.this_contract(), self.dotns_registry.to_addr()];
            let contract_address = self.this_contract();

            let store_addr = store_utils::get_or_create_store(
                &mut self.store_factory,
                controllers,
                registration.owner,
                contract_address,
            )
            .map_err(|_| RegistrarControllerError::InvalidStore)?;

            let mut store_ref = StoreRef::from_addr(store_addr);
            let store_key = self.store_key(labelhash);

            store_ref
                .set_value_for(registration.owner, store_key, full_name)
                .map_err(|_| RegistrarControllerError::CallFailed)?;

            self.env().emit_event(NameRegistered {
                label,
                labelhash,
                owner: registration.owner,
                base_cost: 0,
                store: store_addr,
            });

            Ok(())
        }
    }
}
