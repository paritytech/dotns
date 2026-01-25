use ink::prelude::vec::Vec;
use ink::primitives::H160;

/// Errors that can occur during StoreFactory operations.
#[derive(Debug, Clone, PartialEq, Eq)]
#[ink::error]
pub enum FactoryError {
    /// Attempted to deploy a store for an address that already has one deployed.
    ///
    /// Contains the address of the existing store.
    AlreadyDeployed(H160),

    /// Attempted an invalid ownership transfer operation.
    ///
    /// This error occurs when:
    /// - The caller has no store registered and attempts to transfer
    /// - The target already has a store registered (when target is non-zero)
    ///
    /// Contains the address that caused the invalid transfer attempt.
    InvalidTransfer(H160),

    /// Store deployment succeeded but ownership verification failed.
    ///
    /// The deployed store reported a different owner than expected.
    /// Contains the address of the store that failed validation.
    InvalidOwnership(H160),

    /// Contract instantiation failed during deployment.
    DeploymentFailed,
}

/// Defines operations for deploying and managing user-specific store instances.
///
/// Each address can deploy exactly one store instance. Subsequent deployment
/// attempts will fail with an error. The factory maintains a registry mapping
/// addresses to their deployed stores.
#[ink::trait_definition]
pub trait BaseStoreFactory {
    /// Deploys a new store contract for the caller.
    ///
    /// Creates and initializes a new store instance owned by the message sender.
    /// The store address is registered in the factory's mapping. Each address
    /// can only deploy one store - subsequent calls will fail.
    ///
    /// # Returns
    ///
    /// The address of the newly deployed store contract on success.
    ///
    /// # Errors
    ///
    /// - `AlreadyDeployed` - Caller already has a deployed store
    /// - `DeploymentFailed` - Contract instantiation failed
    /// - `InvalidOwnership` - Deployed store reports incorrect owner
    ///
    /// # Events
    ///
    /// Emits `StoreDeployed` with the owner and store addresses on success.
    #[ink(message)]
    fn deploy(&mut self) -> Result<H160, FactoryError>;

    /// Transfers ownership of a store registry entry.
    ///
    /// Updates the factory's internal mapping to associate the store with a new
    /// owner address. This only affects the factory registry - the store contract's
    /// internal ownership must be updated separately by calling the store's own
    /// transfer function.
    ///
    /// If the new owner is the zero address, the registry entry is effectively
    /// released, though the store contract itself continues to exist.
    ///
    /// # Arguments
    ///
    /// * `new_owner` - Address that will own the registry entry. Zero address releases the entry.
    ///
    /// # Returns
    ///
    /// Unit type on success.
    ///
    /// # Errors
    ///
    /// - `InvalidTransfer` - Caller has no store registered, or target already has one
    ///
    /// # Events
    ///
    /// Emits `OwnershipTransfered` with old and new owner addresses on success.
    #[ink(message)]
    fn transfer_ownership(&mut self, new_owner: H160) -> Result<(), FactoryError>;

    /// Retrieves the store contract address deployed by a specific user.
    ///
    /// Queries the factory registry for the store associated with the given address.
    /// Returns the zero address if no store has been deployed by that address.
    ///
    /// # Arguments
    ///
    /// * `who` - Address of the store owner to query.
    ///
    /// # Returns
    ///
    /// The deployed store address, or zero address if none exists.
    #[ink(message)]

    fn get_deployed_store(&self, who: H160) -> H160;

    /// Returns a list of all deployed store addresses.
    ///
    /// # Returns
    ///
    /// A vector of store addresses.
    #[ink(message)]
    fn deployed_stores(&self) -> Vec<H160>;
}
