use ink::prelude::string::String;
use ink::prelude::vec::Vec;
use ink::primitives::H160;

/// Storage key type (32 bytes).
pub type Key = [u8; 32];

/// Errors for Store operations.
///
/// This enum is returned by Store messages when a call violates access control
/// or attempts to overwrite/delete a permanently locked entry.
#[derive(Debug, Clone, PartialEq, Eq)]
#[ink::error]
pub enum StoreError {
    /// Thrown when an unauthorized address attempts a privileged operation.
    /// - `caller`: The address that attempted the operation.
    NotAuthorised(H160),

    /// Thrown when attempting to overwrite or delete a permanently locked key.
    /// - `user`: The user namespace owner of the key.
    /// - `key`: The key that is locked.
    KeyLocked { user: H160, key: Key },
}

/// Trait defining a key-value storage for IPFS URIs scoped by user address.
///
/// Each user maintains an isolated namespace of key-value pairs.
/// Authorized contracts can write on behalf of users.
///
/// Permanent locking:
/// Some `(user, key)` entries can be locked permanently to make them immutable:
/// - Locked entries cannot be overwritten by any caller.
/// - Locked entries cannot be deleted by any caller, including the store owner.
/// - Intended for data written by a controller that enforces immutability semantics.
#[ink::trait_definition]
pub trait StoreBase {
    /// Store or update an IPFS URI under a given key for the caller.
    ///
    /// Keys are scoped to `env().caller()` to prevent collisions across users.
    ///
    /// # Arguments
    /// - `key`: The unique identifier for the stored value.
    /// - `value`: The IPFS URI to store.
    ///
    /// # Errors
    /// - Returns `StoreError::KeyLocked` if `(env().caller(), key)` is locked permanently.
    #[ink(message)]
    fn set_value(&mut self, key: Key, value: String) -> Result<(), StoreError>;

    /// Store or update an IPFS URI under a given key for a specified user.
    ///
    /// Only authorized contracts can call this function. Keys are scoped to the specified user.
    /// If the caller is a controller, the key may be locked permanently as part of the write.
    ///
    /// # Arguments
    /// - `user`: The address whose storage will be modified.
    /// - `key`: The unique identifier for the stored value.
    /// - `value`: The IPFS URI to store.
    ///
    /// # Errors
    /// - Returns `StoreError::NotAuthorised` if caller is not authorized.
    /// - Returns `StoreError::KeyLocked` if `(user, key)` is locked permanently.
    #[ink(message)]
    fn set_value_for(&mut self, user: H160, key: Key, value: String) -> Result<(), StoreError>;

    /// Retrieve the IPFS URI for a given key from the caller's storage.
    ///
    /// # Arguments
    /// - `key`: The key to look up.
    ///
    /// # Returns
    /// - The stored IPFS URI, or an empty string if none exists.
    #[ink(message)]
    fn get_value(&self, key: Key) -> String;

    /// Retrieve the IPFS URI for a given key from a specified user's storage.
    ///
    /// Allows reading any user's stored data regardless of the caller.
    ///
    /// # Arguments
    /// - `user`: The address whose storage to query.
    /// - `key`: The key to look up.
    ///
    /// # Returns
    /// - The stored IPFS URI, or an empty string if none exists.
    #[ink(message)]
    fn get_value_for(&self, user: H160, key: Key) -> String;

    /// Delete a value associated with a key from the caller's storage.
    ///
    /// # Arguments
    /// - `key`: The key to delete.
    ///
    /// # Errors
    /// - Returns `StoreError::KeyLocked` if `(env().caller(), key)` is locked permanently.
    #[ink(message)]
    fn delete_value(&mut self, key: Key) -> Result<(), StoreError>;

    /// Check if a key has a stored value in the caller's storage.
    ///
    /// # Arguments
    /// - `key`: The key to check.
    ///
    /// # Returns
    /// - `true` if the key has a non-empty value.
    #[ink(message)]
    fn has_value(&self, key: Key) -> bool;

    /// Retrieve all stored values for the caller.
    ///
    /// Returns values in the order they were added. May include duplicates if `set_value`
    /// was called multiple times.
    ///
    /// # Returns
    /// - An array of all IPFS URIs stored by the caller.
    #[ink(message)]
    fn get_values(&self) -> Vec<String>;

    /// Check if an address is authorized to write on behalf of users.
    ///
    /// # Arguments
    /// - `store_address`: The address to check authorization status.
    ///
    /// # Returns
    /// - `true` if the address is authorized.
    #[ink(message)]
    fn is_authorized(&self, store_address: H160) -> bool;

    /// Check if an address is marked as a controller for locking semantics.
    ///
    /// Controllers may cause `(user, key)` writes via `set_value_for` to become permanently locked.
    ///
    /// # Arguments
    /// - `controller_address`: The address to check.
    ///
    /// # Returns
    /// - `true` if the address is a controller.
    #[ink(message)]
    fn is_dotns_controller(&self, controller_address: H160) -> bool;

    /// Check if a `(user, key)` pair is permanently locked.
    ///
    /// # Arguments
    /// - `user`: The user namespace owner of the key.
    /// - `key`: The key to check.
    ///
    /// # Returns
    /// - `true` if the key is locked permanently.
    #[ink(message)]
    fn is_locked(&self, user: H160, key: Key) -> bool;

    /// Authorizes an address to call `set_value_for` on behalf of users.
    ///
    /// Only the store owner can authorize new addresses.
    ///
    /// # Arguments
    /// - `store_address`: The address to authorize.
    ///
    /// # Errors
    /// - Returns `StoreError::NotAuthorised` if caller is not the owner.
    #[ink(message)]
    fn authorize_store(&mut self, store_address: H160) -> Result<(), StoreError>;

    /// Revokes authorization for an address to call `set_value_for`.
    ///
    /// Only the store owner can revoke authorizations.
    ///
    /// # Arguments
    /// - `store_address`: The address to unauthorize.
    ///
    /// # Errors
    /// - Returns `StoreError::NotAuthorised` if caller is not the owner.
    #[ink(message)]
    fn unauthorize_store(&mut self, store_address: H160) -> Result<(), StoreError>;

    /// Marks an address as a controller for locking semantics.
    ///
    /// Only the store owner can grant this role.
    /// This role does not grant write access by itself; the address must also be authorized
    /// via `authorize_store`.
    ///
    /// # Arguments
    /// - `controller_address`: The address to mark as controller.
    ///
    /// # Errors
    /// - Returns `StoreError::NotAuthorised` if caller is not the owner.
    #[ink(message)]
    fn authorize_dotns_controller(&mut self, controller_address: H160) -> Result<(), StoreError>;

    /// Removes controller status from an address.
    ///
    /// Only the store owner can revoke this role.
    /// Revoking does not unlock existing locked keys.
    ///
    /// # Arguments
    /// - `controller_address`: The address to unmark as controller.
    ///
    /// # Errors
    /// - Returns `StoreError::NotAuthorised` if caller is not the owner.
    #[ink(message)]
    fn unauthorize_dotns_controller(&mut self, controller_address: H160) -> Result<(), StoreError>;
}
