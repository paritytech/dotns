//! Base Registrar
//!
//! ERC721-backed ownership for DotNS names with controller-gated registration.
//!
//! # Description
//!
//! # Security Contact
//!
//! admin@parity.io

use ink::primitives::{H160, U256};

/// Errors for the Base Registrar contract.
#[derive(Debug, PartialEq, Eq)]
#[ink::scale_derive(Encode, Decode, TypeInfo)]
pub enum RegistrarError {
    /// Thrown when a name is already registered.
    ///
    /// # Fields
    ///
    /// * `token_id` - The token identifier derived from the label.
    NameNotAvailable { token_id: U256 },

    /// Thrown when the caller is not an authorised controller.
    ///
    /// # Fields
    ///
    /// * `caller` - The caller address.
    NotController { caller: H160 },

    /// Thrown when the caller is not the owner.
    NotOwner,
}

/// Emitted when a name is registered.
///
/// # Fields
///
/// * `id` - Token identifier.
/// * `owner` - Owner of the name.
#[ink::event]
pub struct NameRegistered {
    #[ink(topic)]
    pub id: U256,
    #[ink(topic)]
    pub owner: H160,
}

/// Emitted when a controller is added.
///
/// # Fields
///
/// * `controller` - Address granted controller permissions.
#[ink::event]
pub struct ControllerAdded {
    #[ink(topic)]
    pub controller: H160,
}

/// Emitted when a controller is removed.
///
/// # Fields
///
/// * `controller` - Address whose controller permissions were revoked.
#[ink::event]
pub struct ControllerRemoved {
    #[ink(topic)]
    pub controller: H160,
}

/// Base Registrar
///
/// ERC721-backed ownership for DotNS names with controller-gated registration.
#[ink::trait_definition]
pub trait BaseDotnsRegistrar {
    /// Returns whether a name is available for registration.
    ///
    /// A name is available if and only if it has not been registered yet.
    ///
    /// # Arguments
    ///
    /// * `id` - Token identifier.
    ///
    /// # Returns
    ///
    /// * `bool` - True if the name can be registered.
    #[ink(message)]
    fn available(&self, id: U256) -> bool;

    /// Registers a name permanently.
    ///
    /// Callable only by an authorised controller.
    /// Registration mints the ERC721 token to `owner`.
    ///
    /// # Arguments
    ///
    /// * `id` - Token identifier.
    /// * `owner` - Owner of the name.
    ///
    /// # Errors
    ///
    /// * `NameNotAvailable` - If the name is already registered.
    /// * `NotController` - If the caller is not an authorised controller.
    #[ink(message)]
    fn register(&mut self, id: U256, owner: H160) -> Result<(), RegistrarError>;

    /// Adds an authorised controller.
    ///
    /// Can only be called by the owner.
    ///
    /// # Arguments
    ///
    /// * `controller` - Address to authorise.
    ///
    /// # Errors
    ///
    /// * `NotOwner` - If the caller is not the owner.
    #[ink(message)]
    fn add_controller(&mut self, controller: H160) -> Result<(), RegistrarError>;

    /// Removes an authorised controller.
    ///
    /// Can only be called by the owner.
    ///
    /// # Arguments
    ///
    /// * `controller` - Address to deauthorise.
    ///
    /// # Errors
    ///
    /// * `NotOwner` - If the caller is not the owner.
    #[ink(message)]
    fn remove_controller(&mut self, controller: H160) -> Result<(), RegistrarError>;
}
