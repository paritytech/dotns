//! Reverse Resolver
//!
//! # Description
//!
//! Defines the minimal surface required to associate an address with a human-readable name.
//! Implementations are expected to enforce authorization for writes.
//!
//! # Security Contact
//!
//! admin@parity.io

use ink::prelude::string::String;
use ink::primitives::H160;

/// Errors for the Reverse Resolver contract.
#[derive(Debug, PartialEq, Eq)]
#[ink::scale_derive(Encode, Decode, TypeInfo)]
pub enum ReverseResolverError {
    /// Thrown when a caller is not authorised to modify reverse records.
    NotRegistrarController,

    /// Thrown when an invalid registrar address is provided.
    InvalidRegistrarController,

    /// Thrown when the caller is not the owner.
    NotOwner,
}

#[ink::trait_definition]
pub trait BaseDotnsReverseResolver {
    /// Associates an address with a reverse name record.
    ///
    /// This function overwrites any existing reverse record for `addr`.
    ///
    /// # Arguments
    ///
    /// * `addr` - The address for which the reverse name is being set.
    /// * `name` - The human-readable name associated with the address.
    ///
    /// # Errors
    ///
    /// * `NotRegistrarController` - If the caller is not authorised to write.
    #[ink(message)]
    fn set_reverse_name(&mut self, addr: H160, name: String) -> Result<(), ReverseResolverError>;

    /// Returns the reverse name for an address.
    ///
    /// Returns an empty string if no reverse name is set.
    ///
    /// # Arguments
    ///
    /// * `addr` - The address to query.
    ///
    /// # Returns
    ///
    /// * `String` - The reverse name associated with `addr`.
    #[ink(message)]
    fn name_of(&self, addr: H160) -> String;

    /// Updates the registrar address authorised to write reverse records.
    ///
    /// # Arguments
    ///
    /// * `new_registrar` - The new registrar controller address.
    ///
    /// # Errors
    ///
    /// * `NotOwner` - If the caller is not the owner.
    /// * `InvalidRegistrar` - If `new_registrar` is the zero address.
    #[ink(message)]
    fn update_registrar_controller(
        &mut self,
        new_registrar: H160,
    ) -> Result<(), ReverseResolverError>;
}
