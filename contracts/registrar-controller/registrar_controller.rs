//! Base Registrar Controller
//!
//! Outlines the functions registering .dot labels using a commit-reveal scheme.
//!
//! # Description
//!
//! This file defines allocation only. Forward resolution, reverse lookup, pricing mechanics,
//! PoP validation, and store writing are handled by external contracts.
//!
//! # Commit-Reveal
//!
//! - Users commit a hash of registration parameters.
//! - After a minimum delay, they reveal the same parameters to register.
//!
//! # Store Writing
//!
//! - Implementations write the successfully registered name into the user's Store
//!   to create an immutable onchain record of the name registration.
//! - This store serves as a quick lookup for all names registered.
//!
//! # Security Contact
//!
//! admin@parity.io

use dotns_registrar::registrar::RegistrarError;
use ink::prelude::string::String;
use ink::primitives::{H160, H256};
/// Parameters used to generate and reveal a commitment.
///
/// All fields must match exactly between commitment and reveal.
#[derive(Debug, Clone, PartialEq, Eq)]
#[ink::scale_derive(Encode, Decode, TypeInfo)]
pub struct Registration {
    /// Label being registered (e.g. "alice").
    pub label: String,
    /// Address that will own the registered name.
    pub owner: H160,
    /// Secret used to bind the commitment.
    pub secret: H256,
    /// Whether the name is reserved. This means the name is the default
    /// name assigned that resolvers will point to.
    pub reserved: bool,
}

/// Errors for the Registrar Controller contract.
#[derive(Debug, PartialEq, Eq)]
#[ink::scale_derive(Encode, Decode, TypeInfo)]
pub enum RegistrarControllerError {
    /// Thrown when an unexpired commitment already exists.
    UnexpiredCommitmentExists {
        commitment: H256,
    },

    /// Thrown when revealing a commitment that does not exist.
    CommitmentNotFound {
        commitment: H256,
    },

    /// Thrown when a commitment is revealed before the minimum age.
    CommitmentTooNew {
        commitment: H256,
        min_time: u64,
        current_time: u64,
    },

    /// Thrown when a commitment has expired.
    CommitmentTooOld {
        commitment: H256,
        max_time: u64,
        current_time: u64,
    },

    /// Thrown when attempting to register an unavailable name.
    NameNotAvailable {
        label: String,
    },

    /// Thrown when supplied payment is insufficient.
    InsufficientValue,

    /// Thrown when refund fails.
    RefundFailed,

    /// Thrown when max commitment age is invalid (must be > minCommitmentAge).
    MaxCommitmentAgeTooLow,

    /// Thrown when max commitment age is invalid (exceeds implementation limit).
    MaxCommitmentAgeTooHigh,

    /// Thrown when an invalid Store instance is encountered.
    InvalidStore,

    /// Thrown when the caller is not the registry.
    NotRegistry,

    /// Thrown when the caller is not the owner.
    NotOwner,

    /// Thrown when a cross-contract call fails.
    CallFailed,

    /// Thrown when label is too short (< 3 characters).
    LabelTooShort,

    /// Thrown when the registrar contract call fails.
    RegistrarCallFailed {
        error: RegistrarError,
    },
}

/// Base Registrar Controller
///
/// Defines function registering .dot labels using a commit-reveal scheme.
#[ink::trait_definition]
pub trait BaseDotnsRegistrarController {
    /// Returns whether a label is available for registration.
    ///
    /// # Arguments
    ///
    /// * `label` - Label to check.
    ///
    /// # Returns
    ///
    /// * `bool` - True if the label can be registered.
    #[ink(message)]
    fn available(&self, label: String) -> Result<bool, RegistrarControllerError>;

    /// Computes the commitment hash for a registration.
    ///
    /// # Arguments
    ///
    /// * `registration` - Registration parameters.
    ///
    /// # Returns
    ///
    /// * `H256` - Commitment hash.
    #[ink(message)]
    fn make_commitment(&self, registration: Registration) -> H256;

    /// Submits a commitment for a future registration.
    ///
    /// # Arguments
    ///
    /// * `commitment` - Commitment hash produced by make_commitment.
    ///
    /// # Errors
    ///
    /// * `UnexpiredCommitmentExists` - If an unexpired commitment already exists.
    #[ink(message)]
    fn commit(&mut self, commitment: H256) -> Result<(), RegistrarControllerError>;

    /// Registers a name after the commitment delay.
    ///
    /// Registration parameters must match the committed values.
    ///
    /// # Arguments
    ///
    /// * `registration` - Registration parameters.
    ///
    /// # Errors
    ///
    /// * `NameNotAvailable` - If the name is not available.
    /// * `CommitmentNotFound` - If no commitment exists.
    /// * `CommitmentTooNew` - If commitment hasn't aged enough.
    /// * `CommitmentTooOld` - If commitment has expired.
    /// * `InsufficientValue` - If payment is insufficient.
    #[ink(message, payable)]
    fn register(&mut self, registration: Registration) -> Result<(), RegistrarControllerError>;

    /// Registers a reserved name after the commitment delay.
    ///
    /// Registration parameters must match the committed values.
    /// Can only be called by owner.
    ///
    /// # Arguments
    ///
    /// * `registration` - Registration parameters.
    ///
    /// # Errors
    ///
    /// * `NotOwner` - If caller is not the owner.
    /// * `NameNotAvailable` - If the name is not available.
    /// * `CommitmentNotFound` - If no commitment exists.
    /// * `CommitmentTooNew` - If commitment hasn't aged enough.
    /// * `CommitmentTooOld` - If commitment has expired.
    #[ink(message)]
    fn register_reserved(
        &mut self,
        registration: Registration,
    ) -> Result<(), RegistrarControllerError>;
}
