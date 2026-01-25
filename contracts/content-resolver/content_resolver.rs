//! Content Resolver
//!
//! Defines storage and retrieval for content hash, text records, and operator approvals for DotNS nodes.
//!
//! # Description
//!
//! Content hash and text records point to off-chain content such as IPFS CIDs or future schemes.
//! Operator approvals allow third parties to manage records on behalf of the owner.
//! Interpretation is handled off-chain.
//!
//! # Security Contact
//!
//! admin@parity.io

use ink::prelude::string::String;
use ink::prelude::vec::Vec;
use ink::primitives::{H160, H256};

/// Errors for the Content Resolver contract.
#[derive(Debug, PartialEq, Eq)]
#[ink::scale_derive(Encode, Decode, TypeInfo)]
pub enum ContentResolverError {
    /// Thrown when the caller is not authorised to modify a node.
    ///
    /// # Fields
    ///
    /// * `node` - The node being modified.
    /// * `caller` - The address attempting the modification.
    NotAuthorised { node: H256, caller: H160 },

    /// Thrown when the caller is not the owner.
    NotOwner,
}

/// Content Resolver
///
/// Defines storage and retrieval for content hash, text records, and operator approvals.
#[ink::trait_definition]
pub trait ContentResolver {
    /// Sets the content hash for a node.
    ///
    /// The caller must own the node in the DotNS registry or be an approved operator.
    ///
    /// # Arguments
    ///
    /// * `node` - The node whose content hash is being set.
    /// * `hash` - Opaque content hash bytes.
    ///
    /// # Errors
    ///
    /// * `NotAuthorised` - If the caller is not the node owner or approved operator.
    #[ink(message)]
    fn set_contenthash(&mut self, node: H256, hash: Vec<u8>) -> Result<(), ContentResolverError>;

    /// Returns the content hash associated with a node.
    ///
    /// # Arguments
    ///
    /// * `node` - The node to query.
    ///
    /// # Returns
    ///
    /// * `Vec<u8>` - The stored content hash bytes, or empty if unset.
    #[ink(message)]
    fn contenthash(&self, node: H256) -> Vec<u8>;

    /// Sets a text record for a node.
    ///
    /// The caller must own the node in the DotNS registry or be an approved operator.
    ///
    /// # Arguments
    ///
    /// * `node` - The node whose text record is being set.
    /// * `key` - Text record key (e.g., "ipfs", "avatar").
    /// * `value` - Text record value.
    ///
    /// # Errors
    ///
    /// * `NotAuthorised` - If the caller is not the node owner or approved operator.
    #[ink(message)]
    fn set_text(
        &mut self,
        node: H256,
        key: String,
        value: String,
    ) -> Result<(), ContentResolverError>;

    /// Returns a text record for a node.
    ///
    /// # Arguments
    ///
    /// * `node` - The node to query.
    /// * `key` - Text record key.
    ///
    /// # Returns
    ///
    /// * `String` - Stored text value, or empty string if unset.
    #[ink(message)]
    fn text(&self, node: H256, key: String) -> String;

    /// Enable or disable approval for a third party ("operator") to manage all of caller's nodes.
    ///
    /// # Arguments
    ///
    /// * `operator` - Address to authorize or revoke.
    /// * `approved` - True to approve, false to revoke.
    #[ink(message)]
    fn set_approval_for_all(&mut self, operator: H160, approved: bool);

    /// Query if an address is an approved operator for another address.
    ///
    /// # Arguments
    ///
    /// * `owner` - The owner of the nodes.
    /// * `operator` - The address acting on behalf of the owner.
    ///
    /// # Returns
    ///
    /// * `bool` - True if operator is approved, false otherwise.
    #[ink(message)]
    fn is_approved_for_all(&self, owner: H160, operator: H160) -> bool;
}
