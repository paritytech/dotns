use ink::prelude::string::String;
use ink::H160;

/// Proof-of-Personhood eligibility tier.
///
/// Defines verification requirements for a given name classification.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[ink::scale_derive(Encode, Decode, TypeInfo)]
#[cfg_attr(feature = "std", derive(ink::storage::traits::StorageLayout))]
pub enum PopStatus {
    /// No proof of personhood required.
    #[default]
    NoStatus,
    /// Light proof of personhood verification required.
    PopLite,
    /// Full proof of personhood verification required.
    PopFull,
    /// Reserved for governance; registration not permitted.
    Reserved,
}

/// Bundle returned from metadata-aware pricing queries.
///
/// Contains the cost, required PoP tier, user's current status, and a
/// human-readable classification description.
#[derive(Debug, Clone, PartialEq, Eq)]
#[ink::scale_derive(Encode, Decode, TypeInfo)]
pub struct PriceWithMeta {
    /// The cost the name will incur, usually for PoP NoStatus users.
    pub price: u128,
    /// Required PoP tier for this name.
    pub status: PopStatus,
    /// Currently set user PoP status.
    pub user_status: PopStatus,
    /// Human-readable classification description.
    pub message: String,
}

/// Reservation metadata for a base name (digits removed).
///
/// Stores the address holding exclusive claim rights during the reservation
/// window and the UNIX timestamp when the reservation expires.
#[derive(Debug, Clone, PartialEq, Eq)]
#[ink::scale_derive(Encode, Decode, TypeInfo)]
#[cfg_attr(feature = "std", derive(ink::storage::traits::StorageLayout))]
pub struct Reservation {
    /// Address holding exclusive claim rights during the reservation window.
    pub owner: H160,
    /// UNIX timestamp when the reservation expires.
    pub expires: u64,
}

impl Default for Reservation {
    fn default() -> Self {
        Self {
            owner: H160::zero(),
            expires: 0,
        }
    }
}

/// Classification result returned by `classify_name`.
///
/// Contains the required PoP tier and an explanation of the classification.
#[derive(Debug, Clone, PartialEq, Eq)]
#[ink::scale_derive(Encode, Decode, TypeInfo)]
pub struct Classification {
    /// Required tier for registration.
    pub requirement: PopStatus,
    /// Explanation of classification result.
    pub message: String,
}

/// Result of checking whether a base name is reserved.
///
/// Contains the reservation status, the holder address, and the expiry timestamp.
#[derive(Debug, Clone, PartialEq, Eq)]
#[ink::scale_derive(Encode, Decode, TypeInfo)]
pub struct ReservationStatus {
    /// True if a reservation is currently active.
    pub is_reserved: bool,
    /// The reservation holder address.
    pub owner: H160,
    /// The reservation expiry timestamp.
    pub expires: u64,
}

/// Errors that can occur during PoP rules operations.
///
/// Provides detailed error information for name validation, reservation,
/// and registry operations.
#[derive(Debug, Clone, PartialEq, Eq)]
#[ink::scale_derive(Encode, Decode, TypeInfo)]
pub enum PopRulesError {
    /// Thrown when a name violates PoP-tier or reservation requirements.
    /// Contains a human-readable explanation of the failure condition.
    PopError(String),
    /// Generic error with a human-readable explanation.
    GenericError(String),
    /// Thrown when a function restricted to the registry is called by another address.
    NotRegistry,
    /// Thrown when a function restricted to the owner is called by another address.
    NotOwner,
    /// Thrown when the name is reserved for governance.
    NameReserved,
    /// Thrown when the user lacks sufficient PoP status.
    InsufficientPopStatus,
    /// Thrown when a base name reservation already exists.
    ReservationExists,
    /// Thrown when the name has too many trailing digits.
    TooManyTrailingDigits,
    /// Thrown when attempting to reserve a non-lite-eligible name.
    NotLiteEligible,
}

/// Proof of personhood trait defining DotNS price calculation,
/// PoP-tier requirements, and base-name reservation rules.
///
/// Provides the classification logic for DotNS labels, enforces suffix
/// constraints, and exposes reservation metadata.
///
/// # Naming Rules
///
/// Names are evaluated according to the following rules:
///
/// | Length | Trailing Digits | Requirement |
/// |--------|-----------------|-------------|
/// | ≤ 5    | Any             | Reserved    |
/// | 6–8    | None            | PopFull     |
/// | 6–8    | 2 digits        | PopLite     |
/// | ≥ 9    | None            | PopFull     |
/// | ≥ 9    | 2 digits        | NoStatus    |
///
/// Trailing digits beyond 2 are invalid. Internal digits do not affect
/// classification. Reservation rules apply to a label stripped of trailing
/// digits.
///
/// # Registration Permissions
///
/// For PopFull users, there are no restrictions on name registrations; any
/// character combination is valid. The same applies to PopLite and NoStatus
/// users, with the exception of requiring 2 suffix digits appended to the
/// username being registered.
///
/// # Pricing
///
/// The pricing applied is mainly for PoP NoStatus users as a measure to
/// prevent spam.
#[ink::trait_definition]
pub trait BaseDotnsPopRules {
    /// Sets the Proof-of-Personhood (PoP) tier for the caller's profile.
    ///
    /// Once set, this PoP status applies to all registrations by this user.
    /// This replaces per-name PoP assignments.
    ///
    /// # Arguments
    ///
    /// * `status` - The PoP tier to assign to the user.
    ///
    /// # Note
    ///
    /// This is temporary until we have a Precompile for accessing PoP status.
    #[ink(message)]
    fn set_user_pop_status(&mut self, status: PopStatus);

    /// Retrieves the PoP status for a given user.
    ///
    /// # Arguments
    ///
    /// * `user` - The address to query.
    ///
    /// # Returns
    ///
    /// The user's current `PopStatus`.
    #[ink(message)]
    fn get_user_pop_status(&self, user: H160) -> PopStatus;

    /// Classifies a name into a required PoP tier according to DotNS naming rules.
    ///
    /// # Arguments
    ///
    /// * `name` - The name label being evaluated.
    ///
    /// # Returns
    ///
    /// A `Classification` containing the required tier and explanation.
    #[ink(message)]
    fn classify_name(&self, name: String) -> Result<Classification, PopRulesError>;

    /// Creates a reservation entry for the digit-stripped version of a name.
    ///
    /// # Arguments
    ///
    /// * `name` - The name label (trailing digits will be stripped).
    /// * `user_address` - The address receiving reservation rights.
    ///
    /// # Errors
    ///
    /// Returns `NotRegistry` if called by an address other than the registry.
    /// Returns `NotLiteEligible` if the name does not qualify for lite eligibility.
    #[ink(message)]
    fn reserve_base_name(&mut self, name: String, user_address: H160) -> Result<(), PopRulesError>;

    /// Updates the DOT registry address.
    ///
    /// # Arguments
    ///
    /// * `new_registry` - The address of the new registry.
    ///
    /// # Errors
    ///
    /// Returns `NotOwner` if the caller is not the contract owner.
    #[ink(message)]
    fn update_registry(&mut self, new_registry: H160) -> Result<(), PopRulesError>;

    /// Determines if a given name is a base name.
    ///
    /// A base name is one that has no trailing digits according to PoP rules.
    ///
    /// # Arguments
    ///
    /// * `base_name` - The name to check.
    ///
    /// # Returns
    ///
    /// `true` if the name is a base name (no trailing digits).
    #[ink(message)]
    fn is_base_name(&self, base_name: String) -> bool;

    /// Retrieves reservation information for a base name.
    ///
    /// # Arguments
    ///
    /// * `base_name` - The base label without trailing digits.
    ///
    /// # Returns
    ///
    /// A `Reservation` struct with owner and expiry information.
    #[ink(message)]
    fn get_base_name_reservation(&self, base_name: String) -> Reservation;

    /// Indicates whether a base name is currently reserved.
    ///
    /// # Arguments
    ///
    /// * `base_name` - The base label without trailing digits.
    ///
    /// # Returns
    ///
    /// A `ReservationStatus` struct with reservation details.
    #[ink(message)]
    fn is_base_name_reserved(&self, base_name: String) -> ReservationStatus;

    /// Calculates price with PoP and reservation validation.
    ///
    /// This function will revert on names considered reserved for governance.
    ///
    /// # Arguments
    ///
    /// * `name` - Domain label to price.
    /// * `user_address` - Registering user for the given label.
    ///
    /// # Returns
    ///
    /// A `PriceWithMeta` struct containing price and PoP requirements.
    #[ink(message)]
    fn price_with_check(
        &self,
        name: String,
        user_address: H160,
    ) -> Result<PriceWithMeta, PopRulesError>;

    /// Calculates price with PoP validation without reverting on reserved names.
    ///
    /// # Arguments
    ///
    /// * `name` - Domain label to price.
    /// * `user_address` - Registering user for the given label.
    ///
    /// # Returns
    ///
    /// A `PriceWithMeta` struct containing price and PoP requirements.
    #[ink(message)]
    fn price_without_check(
        &self,
        name: String,
        user_address: H160,
    ) -> Result<PriceWithMeta, PopRulesError>;

    /// Calculates registration cost for a domain label.
    ///
    /// # Arguments
    ///
    /// * `name` - Domain label to price.
    ///
    /// # Returns
    ///
    /// The cost in native tokens for registering the name.
    #[ink(message)]
    fn price(&self, name: String) -> u128;
}
