#![cfg_attr(not(feature = "std"), no_std, no_main)]

#[cfg(test)]
pub mod test_modules;

pub mod resolver;

#[ink::contract]
pub mod dotns_resolver {
    use crate::resolver::{BaseDotnsResolver, ResolverError};
    use dotns_registry::DotnsRegistryRef;
    use dotns_registry::registry::BaseDotnsRegistry;
    use dotns_utils::require;
    use ink::ToAddr;
    use ink::prelude::string::String;
    use ink::primitives::{H160, H256};
    use ink::storage::Mapping;
    /// Emitted when an address record is updated.
    ///
    /// This event is the primary mechanism for off-chain systems to track resolver
    /// state. Indexers should watch for these events to maintain up-to-date
    /// mappings of names to addresses.
    ///
    /// # Fields
    ///
    /// * `node` - The node whose address record changed. This is indexed to allow
    ///   efficient filtering by node.
    /// * `value` - The new resolved address. This may be the zero address if the
    ///   owner is clearing the resolution.
    #[ink(event)]
    pub struct AddressSet {
        /// The node whose address record changed.
        #[ink(topic)]
        pub node: H256,
        /// The new resolved address.
        pub value: H160,
    }

    /// DotNS Resolver Contract
    ///
    /// This contract maintains the mapping from DotNS nodes to their resolved
    /// addresses. It is the canonical implementation of the `BaseDotnsResolver`
    /// trait and is designed to work in conjunction with the DotNS registry.
    ///
    /// The contract uses a simple storage layout with the contract owner address,
    /// a reference to the DotNS registry contract for ownership verification, and
    /// a mapping from node hashes to resolved addresses.
    ///
    /// The contract is initialized with a reference to the registry which cannot
    /// be changed after deployment, ensuring consistent ownership checks.
    #[ink(storage)]
    pub struct DotnsResolver {
        /// Contract owner with administrative privileges.
        contract_owner: H160,
        /// Reference to the DotNS registry contract used for ownership verification.
        registry: DotnsRegistryRef,
        /// Mapping from node identifiers to resolved addresses.
        addresses: Mapping<H256, H160>,
    }

    impl DotnsResolver {
        /// Creates a new Resolver contract.
        ///
        /// This constructor initializes the resolver with a reference to the
        /// DotNS registry. The registry reference is stored and used for all
        /// subsequent ownership checks. The caller becomes the contract owner.
        ///
        /// # Arguments
        ///
        /// * `registry` - A reference to the DotNS registry contract. This must
        ///   be a valid, deployed registry contract.
        #[ink(constructor)]
        pub fn new(registry: DotnsRegistryRef) -> Self {
            let caller = Self::env().caller();

            Self {
                contract_owner: caller,
                registry,
                addresses: Mapping::default(),
            }
        }

        /// Returns the contract owner.
        ///
        /// The contract owner is the address that deployed the contract. This
        /// ownership is currently reserved for future administrative features.
        ///
        /// # Returns
        ///
        /// * `H160` - The contract owner address.
        #[ink(message)]
        pub fn contract_owner(&self) -> H160 {
            self.contract_owner
        }

        /// Returns the registry address.
        ///
        /// This is the address of the DotNS registry contract that this resolver
        /// uses for ownership verification. The registry address is set during
        /// construction and cannot be changed.
        ///
        /// # Returns
        ///
        /// * `H160` - The registry contract address.
        #[ink(message)]
        pub fn registry(&self) -> H160 {
            self.registry.to_addr()
        }

        /// Returns the implementation version.
        ///
        /// This version string follows semantic versioning and is incremented
        /// whenever the contract logic changes.
        ///
        /// # Returns
        ///
        /// * `String` - The current version string.
        #[ink(message)]
        pub fn version(&self) -> String {
            String::from("1.0.0")
        }

        /// Internal authorization check for node ownership.
        ///
        /// This function queries the registry to determine if the caller owns
        /// the specified node. It makes a synchronous cross-contract call to
        /// the registry which is read-only and relatively cheap in terms of gas.
        ///
        /// # Arguments
        ///
        /// * `node` - The node identifier to check ownership of.
        ///
        /// # Errors
        ///
        /// * `ResolverError::NotAuthorised` - If the caller is not the owner
        ///   of the node according to the registry.
        fn require_node_owner(&self, node: H256) -> Result<(), ResolverError> {
            let caller = self.env().caller();
            let owner = self.registry.owner(node);

            require!(
                owner == caller,
                ResolverError::NotAuthorised { node, caller }
            );

            Ok(())
        }
    }

    impl BaseDotnsResolver for DotnsResolver {
        /// Sets the resolved address for a node.
        ///
        /// This function updates the mapping to associate the given node with
        /// the given address. The caller must be the owner of the node as
        /// recorded in the registry. Emits an `AddressSet` event on success.
        ///
        /// # Arguments
        ///
        /// * `node` - The node identifier, typically the namehash of the domain.
        /// * `value` - The address to associate with the node.
        ///
        /// # Errors
        ///
        /// * `ResolverError::NotAuthorised` - The caller does not own this node.
        #[ink(message)]
        fn set_address(&mut self, node: H256, value: H160) -> Result<(), ResolverError> {
            self.require_node_owner(node)?;

            self.addresses.insert(node, &value);

            self.env().emit_event(AddressSet { node, value });

            Ok(())
        }

        /// Returns the resolved address for a node.
        ///
        /// This function performs a simple lookup in the addresses mapping.
        /// It does not perform any authorization checks since reading is public.
        /// Returns the zero address if the node has never been set.
        ///
        /// # Arguments
        ///
        /// * `node` - The node identifier to resolve.
        ///
        /// # Returns
        ///
        /// * `H160` - The resolved address, or zero if not set.
        #[ink(message)]
        fn address_of(&self, node: H256) -> H160 {
            self.addresses.get(node).unwrap_or_default()
        }
    }
}
