//! DotNS Registry Implementation
//!
//! Upgradeable on-chain registry for hierarchical name ownership and resolution.
//!
//! # Description
//!
//! Stores ownership and resolver data for DotNS nodes.
//! Authorisation is enforced strictly via node ownership, except for privileged ownership writes
//! performed by a designated `registrar_controller`.
//!
//! # Security Contact
//!
//! admin@parity.io

#![cfg_attr(not(feature = "std"), no_std, no_main)]

#[cfg(test)]
pub mod test_modules;

pub mod registry;

#[ink::contract]
pub mod dotns_registry {
    use crate::registry::{BaseDotnsRegistry, Record, RegistryError, SubnodeRecord};
    use dotns_reverse_resolver::DotnsReverseResolverRef;
    use dotns_store::store_base::StoreBase;
    use dotns_store::StoreRef;
    use dotns_store_factory::StoreFactoryRef;
    use dotns_utils::{require, store::store_utils, DOTNS_REGISTERED_KEY};
    use ink::env::call::FromAddr;
    use ink::env::hash::{HashOutput, Keccak256};
    use ink::prelude::string::String;
    use ink::prelude::vec;
    use ink::prelude::vec::Vec;
    use ink::primitives::{H160, H256};
    use ink::storage::Mapping;
    use ink::ToAddr;

    /// Emitted when a new subnode owner is set.
    ///
    /// # Fields
    ///
    /// * `node` - Parent node.
    /// * `label` - Labelhash of the created subnode.
    /// * `owner` - New owner of the subnode.
    #[ink(event)]
    pub struct NewOwner {
        #[ink(topic)]
        pub node: H256,
        #[ink(topic)]
        pub label: H256,
        pub owner: H160,
    }

    /// Emitted when ownership of a node is transferred.
    ///
    /// # Fields
    ///
    /// * `node` - Node whose owner changed.
    /// * `owner` - New owner of the node.
    #[ink(event)]
    pub struct NodeTransferred {
        #[ink(topic)]
        pub node: H256,
        pub owner: H160,
    }

    /// Emitted when a resolver is set or updated.
    ///
    /// # Fields
    ///
    /// * `node` - Node whose resolver changed.
    /// * `resolver` - New resolver for the node.
    #[ink(event)]
    pub struct NewResolver {
        #[ink(topic)]
        pub node: H256,
        pub resolver: H160,
    }

    /// Emitted when the registrar controller address is updated.
    ///
    /// # Fields
    ///
    /// * `old_registrar_controller` - Previous registrar controller.
    /// * `new_registrar_controller` - New registrar controller.
    #[ink(event)]
    pub struct RegistrarControllerUpdated {
        #[ink(topic)]
        pub old_registrar_controller: H160,
        #[ink(topic)]
        pub new_registrar_controller: H160,
    }

    /// DotNS Registry Contract
    ///
    /// On-chain registry for hierarchical name ownership and resolution.
    #[ink(storage)]
    pub struct DotnsRegistry {
        /// Contract owner with admin privileges.
        contract_owner: H160,
        /// Mapping of node identifiers to records.
        records: Mapping<H256, Record>,
        /// Address authorised to perform privileged ownership writes.
        /// Note: Stored as H160 to avoid circular dependency with registrar-controller.
        registrar_controller: H160,
        /// DotNS Reverse Resolver.
        reverse_resolver: DotnsReverseResolverRef,
        /// Factory for per-user Store instances.
        store_factory: StoreFactoryRef,
    }

    impl DotnsRegistry {
        /// Creates a new Registry contract.
        ///
        /// Sets the deployer as the owner and initializes the root node (bytes32(0)).
        /// Root node owner is set to the caller.
        ///
        /// # Arguments
        ///
        /// * `reverse_resolver` - Address of the DotNS reverse resolver contract.
        /// * `store_factory` - The store factory used for per-user deployment stores.
        #[ink(constructor)]
        pub fn new(
            reverse_resolver: DotnsReverseResolverRef,
            store_factory: StoreFactoryRef,
        ) -> Self {
            let caller = Self::env().caller();

            let mut records = Mapping::default();
            let root_record = Record {
                owner: caller,
                resolver: H160::default(),
                exists: true,
            };
            records.insert(H256::default(), &root_record);

            Self {
                contract_owner: caller,
                records,
                registrar_controller: H160::default(),
                reverse_resolver,
                store_factory,
            }
        }

        /// Returns the contract owner.
        ///
        /// # Returns
        ///
        /// * `H160` - The contract owner address.
        #[ink(message)]
        pub fn contract_owner(&self) -> H160 {
            self.contract_owner
        }

        /// Returns the registrar controller address.
        ///
        /// # Returns
        ///
        /// * `H160` - The registrar controller address.
        #[ink(message)]
        pub fn registrar_controller(&self) -> H160 {
            self.registrar_controller
        }

        /// Returns the reverse resolver address.
        ///
        /// # Returns
        ///
        /// * `H160` - The reverse resolver address.
        #[ink(message)]
        pub fn reverse_resolver(&self) -> H160 {
            self.reverse_resolver.to_addr()
        }

        /// Returns the store factory address.
        ///
        /// # Returns
        ///
        /// * `H160` - The store factory address.
        #[ink(message)]
        pub fn store_factory(&self) -> H160 {
            self.store_factory.to_addr()
        }

        /// Returns the implementation version.
        ///
        /// # Returns
        ///
        /// * `String` - Current version string.
        #[ink(message)]
        pub fn version(&self) -> String {
            String::from("1.2.0")
        }

        /// Transfers ownership of the contract.
        ///
        /// Can only be called by the current owner.
        ///
        /// # Arguments
        ///
        /// * `new_owner` - The new owner address.
        ///
        /// # Errors
        ///
        /// * `NotOwner` - If the caller is not the current owner.
        #[ink(message)]
        pub fn transfer_ownership(&mut self, new_owner: H160) -> Result<(), RegistryError> {
            require!(
                self.env().caller() == self.contract_owner,
                RegistryError::NotOwner
            );
            self.contract_owner = new_owner;
            Ok(())
        }

        /// Computes keccak256(label).
        ///
        /// # Arguments
        ///
        /// * `label` - Label string.
        ///
        /// # Returns
        ///
        /// * `H256` - keccak256(label).
        fn labelhash(&self, label: &str) -> H256 {
            let mut output = <Keccak256 as HashOutput>::Type::default();
            ink::env::hash_bytes::<Keccak256>(label.as_bytes(), &mut output);
            H256::from(output)
        }

        /// Computes namehash(parent_node, labelhash).
        ///
        /// # Arguments
        ///
        /// * `parent_node` - Parent node hash.
        /// * `labelhash` - keccak256(label).
        ///
        /// # Returns
        ///
        /// * `H256` - Derived subnode hash.
        fn namehash(&self, parent_node: H256, labelhash: H256) -> H256 {
            let mut data = [0u8; 64];
            data[..32].copy_from_slice(parent_node.as_bytes());
            data[32..].copy_from_slice(labelhash.as_bytes());

            let mut output = <Keccak256 as HashOutput>::Type::default();
            ink::env::hash_bytes::<Keccak256>(&data, &mut output);
            H256::from(output)
        }

        /// Computes keccak256("dotns.registered", labelhash).
        ///
        /// # Arguments
        ///
        /// * `labelhash` - keccak256(label).
        ///
        /// # Returns
        ///
        /// * `[u8; 32]` - Store key used for DotNS-written registration entry.
        fn store_key(&self, labelhash: H256) -> [u8; 32] {
            let mut data = [0u8; 64];
            data[..32].copy_from_slice(DOTNS_REGISTERED_KEY.as_bytes());
            data[32..].copy_from_slice(labelhash.as_bytes());

            let mut output = <Keccak256 as HashOutput>::Type::default();
            ink::env::hash_bytes::<Keccak256>(&data, &mut output);
            output
        }

        /// Internal authorisation check for node ownership.
        ///
        /// # Arguments
        ///
        /// * `node` - Node identifier.
        ///
        /// # Errors
        ///
        /// * `NotAuthorised` - If caller is not the node owner.
        fn require_authorised(&self, node: H256) -> Result<(), RegistryError> {
            let record = self.records.get(node).unwrap_or_default();
            require!(
                record.owner == self.env().caller(),
                RegistryError::NotAuthorised
            );
            Ok(())
        }

        /// Internal check for registrar controller privileges.
        ///
        /// # Errors
        ///
        /// * `NotRegistryController` - If caller is not the registrar controller.
        fn require_registrar_controller(&self) -> Result<(), RegistryError> {
            require!(
                self.env().caller() == self.registrar_controller,
                RegistryError::NotRegistryController
            );
            Ok(())
        }

        /// Converts the contract's account ID to H160.
        ///
        /// Handles both 20-byte (revive) and 32-byte (test) account IDs.
        ///
        /// # Returns
        ///
        /// * `H160` - The contract's address as H160.
        fn account_to_h160(&self) -> H160 {
            let account_id = self.env().account_id();
            let bytes: &[u8] = account_id.as_ref();
            if bytes.len() == 20 {
                H160::from_slice(bytes)
            } else {
                H160::from_slice(&bytes[..20])
            }
        }

        /// Writes subnode registration to the owner's Store.
        ///
        /// Acquires or deploys a Store for the owner, then writes the full subnode name.
        ///
        /// # Arguments
        ///
        /// * `record` - Subnode record containing owner and label information.
        /// * `labelhash` - Precomputed keccak256 hash of the sublabel.
        ///
        /// # Errors
        ///
        /// * `CallFailed` - If store acquisition or value write fails.
        fn write_subnode_to_store(
            &mut self,
            record: &SubnodeRecord,
            labelhash: H256,
        ) -> Result<(), RegistryError> {
            let this_addr = self.account_to_h160();
            let controllers: Vec<H160> = vec![this_addr];

            let store_addr = store_utils::get_or_create_store(
                &mut self.store_factory,
                controllers,
                record.owner,
                this_addr,
            )
            .map_err(|_| RegistryError::CallFailed)?;

            let mut store_ref = StoreRef::from_addr(store_addr);

            let store_key = self.store_key(labelhash);

            let mut full_name = record.sub_label.clone();
            full_name.push_str(".");
            full_name.push_str(&record.parent_label);
            full_name.push_str(".dot");

            store_ref
                .set_value_for(record.owner, store_key, full_name)
                .map_err(|_| RegistryError::CallFailed)?;

            Ok(())
        }
    }

    impl BaseDotnsRegistry for DotnsRegistry {
        /// Creates a new subnode and assigns its owner.
        ///
        /// Callable only by the current owner of `node`.
        /// Reverts if the derived subnode already exists.
        ///
        /// # Arguments
        ///
        /// * `record` - SubnodeRecord containing parent node, labels, and owner.
        ///
        /// # Returns
        ///
        /// * `H256` - The derived subnode identifier.
        ///
        /// # Errors
        ///
        /// * `NotAuthorised` - If caller is not the parent node owner.
        /// * `NotAllowed` - If new owner is zero address.
        /// * `NodeAlreadyExists` - If subnode already exists.
        /// * `CallFailed` - If store write fails.
        #[ink(message)]
        fn set_subnode_owner(&mut self, record: SubnodeRecord) -> Result<H256, RegistryError> {
            self.require_authorised(record.parent_node)?;

            require!(record.owner != H160::default(), RegistryError::NotAllowed);

            let labelhash = self.labelhash(&record.sub_label);
            let subnode = self.namehash(record.parent_node, labelhash);

            let existing_record = self.records.get(subnode).unwrap_or_default();
            require!(
                !existing_record.exists,
                RegistryError::NodeAlreadyExists { subnode }
            );

            let new_record = Record {
                owner: record.owner,
                resolver: self.reverse_resolver.to_addr(),
                exists: true,
            };
            self.records.insert(subnode, &new_record);

            self.write_subnode_to_store(&record, labelhash)?;

            self.env().emit_event(NewOwner {
                node: record.parent_node,
                label: labelhash,
                owner: record.owner,
            });

            Ok(subnode)
        }

        /// Transfers ownership of an existing node.
        ///
        /// Callable only by the configured `registrar_controller`.
        /// This is a privileged operation used by the registrar controller during registration flows.
        ///
        /// # Arguments
        ///
        /// * `node` - Node identifier.
        /// * `new_owner` - New owner address.
        /// * `resolver_addr` - Resolver address to set for the node.
        ///
        /// # Errors
        ///
        /// * `NotRegistryController` - If caller is not the registrar controller.
        /// * `NotAllowed` - If new owner is zero address.
        /// * `NodeAlreadyOwned` - If node already exists.
        #[ink(message)]
        fn set_owner(
            &mut self,
            node: H256,
            new_owner: H160,
            resolver_addr: H160,
        ) -> Result<(), RegistryError> {
            self.require_registrar_controller()?;

            require!(new_owner != H160::default(), RegistryError::NotAllowed);

            let existing_record = self.records.get(node).unwrap_or_default();
            require!(
                !existing_record.exists,
                RegistryError::NodeAlreadyOwned { node }
            );

            let new_record = Record {
                owner: new_owner,
                resolver: resolver_addr,
                exists: true,
            };
            self.records.insert(node, &new_record);

            self.env().emit_event(NodeTransferred {
                node,
                owner: new_owner,
            });

            Ok(())
        }

        /// Sets or clears the resolver for a node.
        ///
        /// Callable only by the current node owner.
        ///
        /// # Arguments
        ///
        /// * `node` - Node identifier.
        /// * `resolver_addr` - Resolver contract address (zero clears).
        ///
        /// # Errors
        ///
        /// * `NotAuthorised` - If caller is not the node owner.
        #[ink(message)]
        fn set_resolver(&mut self, node: H256, resolver_addr: H160) -> Result<(), RegistryError> {
            self.require_authorised(node)?;

            let mut record = self.records.get(node).unwrap_or_default();
            record.resolver = resolver_addr;
            self.records.insert(node, &record);

            self.env().emit_event(NewResolver {
                node,
                resolver: resolver_addr,
            });

            Ok(())
        }

        /// Returns the owner of a node.
        ///
        /// # Arguments
        ///
        /// * `node` - Node identifier.
        ///
        /// # Returns
        ///
        /// * `H160` - The owner address.
        #[ink(message)]
        fn owner(&self, node: H256) -> H160 {
            self.records.get(node).unwrap_or_default().owner
        }

        /// Returns the resolver of a node.
        ///
        /// # Arguments
        ///
        /// * `node` - Node identifier.
        ///
        /// # Returns
        ///
        /// * `H160` - The resolver address.
        #[ink(message)]
        fn resolver(&self, node: H256) -> H160 {
            self.records.get(node).unwrap_or_default().resolver
        }

        /// Returns whether a node exists.
        ///
        /// # Arguments
        ///
        /// * `node` - Node identifier.
        ///
        /// # Returns
        ///
        /// * `bool` - True if the node exists.
        #[ink(message)]
        fn record_exists(&self, node: H256) -> bool {
            self.records.get(node).unwrap_or_default().exists
        }

        /// Sets the registrar controller used for privileged node ownership writes.
        ///
        /// Callable only by the registry owner.
        ///
        /// # Arguments
        ///
        /// * `new_registrar_controller` - Address of the registrar controller contract.
        ///
        /// # Errors
        ///
        /// * `NotOwner` - If caller is not the registry owner.
        /// * `NotAllowed` - If registrar controller is zero address.
        #[ink(message)]
        fn update_registrar_controller(
            &mut self,
            new_registrar_controller: H160,
        ) -> Result<(), RegistryError> {
            require!(
                self.env().caller() == self.contract_owner,
                RegistryError::NotOwner
            );
            require!(
                new_registrar_controller != H160::default(),
                RegistryError::NotAllowed
            );

            let old_registrar_controller = self.registrar_controller;
            self.registrar_controller = new_registrar_controller;

            self.env().emit_event(RegistrarControllerUpdated {
                old_registrar_controller,
                new_registrar_controller,
            });

            Ok(())
        }
    }
}
