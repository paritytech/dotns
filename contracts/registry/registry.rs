//! Base Registry
//!
//! Minimal on-chain registry for hierarchical name ownership and resolution.
//!
//! # Description
//!
//! Defines the canonical storage and mutation surface for DotNS nodes.
//! The registry is intentionally minimal and self-contained:
//! - Tracks ownership of nodes in a hierarchy
//! - Associates nodes with resolver contracts
//! - Enforces authorisation strictly via node ownership (or explicit controller for privileged ops)
//!
//! # Security Contact
//!
//! admin@parity.io

use ink::prelude::string::String;
use ink::primitives::{H160, H256};

/// Record describing a subnode creation request.
///
/// # Fields
///
/// * `parent_node` - Parent node.
/// * `sub_label` - Human readable subnode label e.g "alice".
/// * `parent_label` - Human readable parent label e.g. "bob".
/// * `owner` - Address to assign as owner of the created subnode.
#[derive(Debug, Clone, PartialEq, Eq)]
#[ink::scale_derive(Encode, Decode, TypeInfo)]
pub struct SubnodeRecord {
    /// Parent node.
    pub parent_node: H256,
    /// Human readable subnode label e.g "alice".
    pub sub_label: String,
    /// Human readable parent label e.g. "bob".
    pub parent_label: String,
    /// Address to assign as owner of the created subnode.
    pub owner: H160,
}

/// Record describing the state of a node.
///
/// # Fields
///
/// * `owner` - Address that owns the node.
/// * `resolver` - Address of the resolver associated with the node.
/// * `exists` - Whether the node has been explicitly created.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
#[ink::scale_derive(Encode, Decode, TypeInfo)]
#[cfg_attr(feature = "std", derive(ink::storage::traits::StorageLayout))]
pub struct Record {
    /// Address that owns the node.
    pub owner: H160,
    /// Address of the resolver associated with the node.
    pub resolver: H160,
    /// Whether the node has been explicitly created.
    pub exists: bool,
}

/// Errors for the Registry contract.
#[derive(Debug, PartialEq, Eq)]
#[ink::scale_derive(Encode, Decode, TypeInfo)]
pub enum RegistryError {
    /// Thrown when an invalid (zero) address is provided.
    NotAllowed,

    /// Thrown when the caller is not authorised.
    NotAuthorised,

    /// Thrown when the caller is not the registry controller.
    NotRegistryController,

    /// Thrown when attempting to create a node that already exists.
    NodeAlreadyOwned { node: H256 },

    /// Thrown when attempting to create a subnode that already exists.
    NodeAlreadyExists { subnode: H256 },

    /// Thrown when the caller is not the owner.
    NotOwner,

    /// Thrown when a cross-contract call fails.
    CallFailed,
}

/// Base Registry Trait
///
/// Minimal on-chain registry for hierarchical name ownership and resolution.
#[ink::trait_definition]
pub trait BaseDotnsRegistry {
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
    #[ink(message)]
    fn set_subnode_owner(&mut self, record: SubnodeRecord) -> Result<H256, RegistryError>;

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
    ) -> Result<(), RegistryError>;

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
    fn set_resolver(&mut self, node: H256, resolver_addr: H160) -> Result<(), RegistryError>;

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
    fn owner(&self, node: H256) -> H160;

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
    fn resolver(&self, node: H256) -> H160;

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
    fn record_exists(&self, node: H256) -> bool;

    /// Sets the registrar controller used for privileged node ownership writes.
    ///
    /// Callable only by the registry owner.
    ///
    /// # Arguments
    ///
    /// * `registrar_controller` - Address of the registrar controller contract.
    ///
    /// # Errors
    ///
    /// * `NotOwner` - If caller is not the registry owner.
    /// * `NotAllowed` - If registrar controller is zero address.
    #[ink(message)]
    fn update_registrar_controller(
        &mut self,
        registrar_controller: H160,
    ) -> Result<(), RegistryError>;
}
