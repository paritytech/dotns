//! Base Resolver
//!
//! Forward-resolution address records for DotNS nodes.
//!
//! # Description
//!
//! This module defines the canonical functions for resolving DotNS nodes to addresses.
//! The resolver provides the mapping from human-readable names (represented as node hashes)
//! to machine-readable addresses that can be used to send transactions or interact with contracts.
//!
//! The design philosophy here is intentionally minimalist. A resolver does exactly one
//! thing: it maps nodes to addresses.
//!
//! The resolver enforces a strict authorization model: only the owner of a node (as
//! recorded in the registry) can modify that node's resolved address. This ensures
//! that names cannot be hijacked by malicious actors.
//!
//! # Considerations
//!
//! When a user wants to resolve a name:
//! 1. The client computes the namehash of the name
//! 2. The client queries the registry to get the resolver address for that node
//! 3. The client queries the resolver to get the resolved address
//!
//! When a user wants to update their resolved address:
//! 1. The user calls `set_address` on the resolver
//! 2. The resolver checks with the registry that the caller owns the node
//! 3. If authorized, the resolver updates the mapping
//!
//! # Limitations
//!
//! The resolver does not validate that addresses being set are "valid" in any sense
//! (e.g., that they are contracts, or that they have code). This is intentional:
//! users should be free to resolve names to any address they choose, including EOAs,
//! contracts, or even the zero address (to effectively "unset" a resolution).
//!
//! # Security Contact
//!
//! admin@parity.io

use ink::primitives::{H160, H256};

/// Errors that can occur during resolver operations.
///
/// The resolver has a deliberately small error surface. Most operations either
/// succeed or fail due to authorization issues. This simplicity makes it easier
/// to reason about what can go wrong and how to handle it.
#[derive(Debug, PartialEq, Eq)]
#[ink::scale_derive(Encode, Decode, TypeInfo)]
pub enum ResolverError {
    /// The caller is not authorised to modify this node.
    ///
    /// This error is returned when someone attempts to call `set_address` for
    /// a node that they do not own according to the registry. The error includes
    /// the node hash and the caller's address for debugging purposes.
    NotAuthorised {
        /// The node that the caller attempted to modify.
        node: H256,
        /// The address of the unauthorized caller.
        caller: H160,
    },

    /// A cross-contract call to the registry failed.
    ///
    /// This error indicates an infrastructure-level failure rather than a
    /// business logic error. The registry may be temporarily unavailable,
    /// the call may have run out of gas, or there may be some other issue.
    RegistryCallFailed,
}

/// Base Resolver
///
/// This trait defines the core functions that all DotNS resolvers must implement.
#[ink::trait_definition]
pub trait BaseDotnsResolver {
    /// Sets the resolved address for a node.
    ///
    /// This function updates the address that a node resolves to. Only the owner
    /// of the node (as recorded in the registry) can call this function. The
    /// function emits an `AddressSet` event on success.
    ///
    /// # Arguments
    ///
    /// * `node` - The node identifier, typically computed as the namehash of the
    ///   fully-qualified domain name.
    /// * `value` - The address to associate with the node. This can be any valid
    ///   address, including the zero address to effectively "unset" the resolution.
    ///
    /// # Returns
    ///
    /// * `Ok(())` - The address was successfully set.
    /// * `Err(ResolverError::NotAuthorised)` - The caller does not own this node.
    /// * `Err(ResolverError::RegistryCallFailed)` - Failed to query the registry.
    ///
    /// # Events
    ///
    /// Emits an `AddressSet` event with the node and new address.
    #[ink(message)]
    fn set_address(&mut self, node: H256, value: H160) -> Result<(), ResolverError>;

    /// Returns the resolved address for a node.
    ///
    /// This function queries the resolver's internal mapping to find the address
    /// associated with a node. It does not perform any authorization checks, as
    /// reading is a public operation.
    ///
    /// # Arguments
    ///
    /// * `node` - The node identifier to resolve, typically computed as the
    ///   namehash of the fully-qualified domain name.
    ///
    /// # Returns
    ///
    /// * `H160` - The resolved address, or the zero address if the node has never
    ///   been set or was explicitly set to zero.
    #[ink(message)]
    fn address_of(&self, node: H256) -> H160;
}
