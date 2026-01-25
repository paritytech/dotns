#![cfg_attr(not(feature = "std"), no_std, no_main)]

#[cfg(test)]
pub mod test_modules;

pub mod content_resolver;
#[ink::contract]
pub mod dotns_content_resolver {
    use crate::content_resolver::ContentResolver;
    use crate::content_resolver::ContentResolverError;
    use dotns_registry::DotnsRegistryRef;
    use dotns_registry::registry::BaseDotnsRegistry;
    use dotns_utils::require;
    use ink::H256;
    use ink::prelude::string::String;
    use ink::prelude::vec::Vec;
    use ink::primitives::H160;
    use ink::storage::Mapping;

    /// Emitted when a node's content hash is updated.
    ///
    /// # Fields
    ///
    /// * `node` - The node whose content hash was updated.
    /// * `hash` - The new content hash bytes.
    #[ink(event)]
    pub struct ContentHashUpdated {
        #[ink(topic)]
        pub node: H256,
        pub hash: Vec<u8>,
    }

    /// Emitted when a node's text record is updated.
    ///
    /// # Fields
    ///
    /// * `node` - The node whose text record was updated.
    /// * `key` - The text record key.
    /// * `value` - The new text record value.
    #[ink(event)]
    pub struct TextUpdated {
        #[ink(topic)]
        pub node: H256,
        #[ink(topic)]
        pub key: String,
        pub value: String,
    }

    /// Emitted when an operator is approved or revoked.
    ///
    /// # Fields
    ///
    /// * `owner` - The owner of the nodes.
    /// * `operator` - The operator address.
    /// * `approved` - True if approved, false if revoked.
    #[ink(event)]
    pub struct ApprovalForAll {
        #[ink(topic)]
        pub owner: H160,
        #[ink(topic)]
        pub operator: H160,
        pub approved: bool,
    }

    /// DotNS Content Resolver Contract
    ///
    /// Stores content hash, text records, and operator approvals for DotNS nodes.
    #[ink(storage)]
    pub struct DotnsContentResolver {
        /// Contract owner with admin privileges.
        owner: H160,
        /// DotNS registry used for ownership checks.
        registry: DotnsRegistryRef,
        /// Node to content hash mapping.
        contenthashes: Mapping<H256, Vec<u8>>,
        /// Node to (key, value) text records mapping.
        text_records: Mapping<(H256, String), String>,
        /// Owner to operator to approval mapping.
        operators: Mapping<(H160, H160), bool>,
    }

    impl DotnsContentResolver {
        /// Creates a new Content Resolver contract.
        ///
        /// # Arguments
        ///
        /// * `registry` - Address of the DotNS registry contract.
        #[ink(constructor)]
        pub fn new(registry: DotnsRegistryRef) -> Self {
            let caller = Self::env().caller();
            Self {
                owner: caller,
                registry,
                contenthashes: Mapping::default(),
                text_records: Mapping::default(),
                operators: Mapping::default(),
            }
        }

        /// Returns the contract owner.
        ///
        /// # Returns
        ///
        /// * `H160` - The contract owner address.
        #[ink(message)]
        pub fn owner(&self) -> H160 {
            self.owner
        }

        /// Returns the implementation version.
        ///
        /// # Returns
        ///
        /// * `String` - Current version string.
        #[ink(message)]
        pub fn version(&self) -> String {
            String::from("1.0.0")
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
        pub fn transfer_ownership(&mut self, new_owner: H160) -> Result<(), ContentResolverError> {
            require!(
                self.env().caller() == self.owner,
                ContentResolverError::NotOwner
            );
            self.owner = new_owner;
            Ok(())
        }

        /// Ensures caller is either the node owner or an approved operator.
        ///
        /// # Arguments
        ///
        /// * `node` - Node identifier.
        ///
        /// # Errors
        ///
        /// * `NotAuthorised` - If caller is not owner or approved operator.
        fn require_node_owner_or_operator(&self, node: H256) -> Result<(), ContentResolverError> {
            let caller = self.env().caller();
            let node_owner = self.registry.owner(node);

            require!(
                caller == node_owner || self.operators.get((node_owner, caller)).unwrap_or(false),
                ContentResolverError::NotAuthorised { node, caller }
            );

            Ok(())
        }
    }

    impl ContentResolver for DotnsContentResolver {
        #[ink(message)]
        fn set_contenthash(
            &mut self,
            node: H256,
            hash: Vec<u8>,
        ) -> Result<(), ContentResolverError> {
            self.require_node_owner_or_operator(node)?;

            self.contenthashes.insert(node, &hash);

            self.env().emit_event(ContentHashUpdated { node, hash });

            Ok(())
        }

        #[ink(message)]
        fn contenthash(&self, node: H256) -> Vec<u8> {
            self.contenthashes.get(node).unwrap_or_default()
        }

        #[ink(message)]
        fn set_text(
            &mut self,
            node: H256,
            key: String,
            value: String,
        ) -> Result<(), ContentResolverError> {
            self.require_node_owner_or_operator(node)?;

            self.text_records.insert((node, key.clone()), &value);

            self.env().emit_event(TextUpdated { node, key, value });

            Ok(())
        }

        #[ink(message)]
        fn text(&self, node: H256, key: String) -> String {
            self.text_records.get((node, key)).unwrap_or_default()
        }

        #[ink(message)]
        fn set_approval_for_all(&mut self, operator: H160, approved: bool) {
            let caller = self.env().caller();
            self.operators.insert((caller, operator), &approved);

            self.env().emit_event(ApprovalForAll {
                owner: caller,
                operator,
                approved,
            });
        }

        #[ink(message)]
        fn is_approved_for_all(&self, owner: H160, operator: H160) -> bool {
            self.operators.get((owner, operator)).unwrap_or(false)
        }
    }
}
