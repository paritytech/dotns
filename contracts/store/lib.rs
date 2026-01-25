#![cfg_attr(not(feature = "std"), no_std, no_main)]

#[cfg(test)]
pub mod test_modules;

pub mod store_base;

#[ink::contract]
pub mod dotns_store {
    use crate::store_base::{Key, StoreBase, StoreError};
    use ink::prelude::string::String;
    use ink::prelude::vec::Vec;
    use ink::primitives::H160;
    use ink::storage::Mapping;

    /// Emitted when a new value is stored or updated.
    ///
    /// # Topics
    /// - `user`: The address whose storage was modified.
    /// - `key`: The key under which the value is stored.
    #[ink(event)]
    pub struct ValueStored {
        #[ink(topic)]
        user: H160,
        #[ink(topic)]
        key: Key,
        value: String,
    }

    /// Emitted when a value is deleted.
    ///
    /// # Topics
    /// - `user`: The address whose storage was modified.
    /// - `key`: The key that was deleted.
    #[ink(event)]
    pub struct ValueDeleted {
        #[ink(topic)]
        user: H160,
        #[ink(topic)]
        key: Key,
    }

    /// Emitted when an address is authorized to write on behalf of users.
    ///
    /// # Topics
    /// - `authorized_address`: The address that was granted authorization.
    #[ink(event)]
    pub struct StoreAuthorized {
        #[ink(topic)]
        authorized_address: H160,
    }

    /// Emitted when an address loses authorization to write on behalf of users.
    ///
    /// # Topics
    /// - `unauthorized_address`: The address that had authorization revoked.
    #[ink(event)]
    pub struct StoreUnauthorized {
        #[ink(topic)]
        unauthorized_address: H160,
    }

    /// Emitted when an authorized address is marked as a controller for locking semantics.
    ///
    /// # Topics
    /// - `controller_address`: The address that was granted controller status.
    #[ink(event)]
    pub struct DotnsControllerAuthorized {
        #[ink(topic)]
        controller_address: H160,
    }

    /// Emitted when an address loses controller status.
    ///
    /// # Topics
    /// - `controller_address`: The address that had controller status revoked.
    #[ink(event)]
    pub struct DotnsControllerUnauthorized {
        #[ink(topic)]
        controller_address: H160,
    }

    /// Emitted when a key is locked permanently for a user.
    ///
    /// # Topics
    /// - `user`: The address whose key was locked.
    /// - `key`: The key that was locked.
    /// - `locker`: The address that caused the lock.
    #[ink(event)]
    pub struct KeyLockedPermanently {
        #[ink(topic)]
        user: H160,
        #[ink(topic)]
        key: Key,
        #[ink(topic)]
        locker: H160,
    }

    /// Emitted when ownership is transferred.
    ///
    /// # Topics
    /// - `previous_owner`: The previous owner.
    /// - `new_owner`: The new owner.
    #[ink(event)]
    pub struct OwnershipTransferred {
        #[ink(topic)]
        previous_owner: H160,
        #[ink(topic)]
        new_owner: H160,
    }

    /// Key-value storage for IPFS URIs, isolated per user address with authorization support.
    ///
    /// Each address manages its own mapping of keys to values.
    /// Authorized contracts can write on behalf of users to enable atomic multi-contract operations.
    ///
    /// Permanent locking:
    /// - A `(user, key)` can be locked permanently.
    /// - Locked keys cannot be overwritten or deleted by any caller, including `owner`.
    /// - Keys are locked automatically when written via `set_value_for` by an address marked as a controller.
    #[ink(storage)]
    pub struct Store {
        /// Contract owner.
        owner: H160,

        /// Primary data: `(user, key) -> value`.
        store: Mapping<(H160, Key), String>,

        /// Secondary data: `user -> all values in insertion order` (append-only, not pruned on delete).
        values: Mapping<H160, Vec<String>>,

        /// Addresses authorized to call `set_value_for`.
        authorized_stores: Mapping<H160, bool>,

        /// Addresses treated as controllers for locking semantics.
        dotns_controllers: Mapping<H160, bool>,

        /// `(user, key) -> locked`.
        locked_keys: Mapping<(H160, Key), bool>,
    }

    impl Store {
        #[ink(constructor)]
        pub fn new() -> Self {
            let owner = Self::env().caller();
            Self {
                owner,
                store: Mapping::default(),
                values: Mapping::default(),
                authorized_stores: Mapping::default(),
                dotns_controllers: Mapping::default(),
                locked_keys: Mapping::default(),
            }
        }

        #[ink(message)]
        pub fn owner(&self) -> H160 {
            self.owner
        }

        #[ink(message)]
        pub fn transfer_ownership(&mut self, new_owner: H160) -> Result<(), StoreError> {
            self.only_owner()?;
            let previous_owner = self.owner;
            self.owner = new_owner;
            self.env().emit_event(OwnershipTransferred {
                previous_owner,
                new_owner,
            });
            Ok(())
        }

        fn only_owner(&self) -> Result<(), StoreError> {
            let caller = self.env().caller();
            if caller != self.owner {
                return Err(StoreError::NotAuthorised(caller));
            }

            Ok(())
        }

        fn only_authorized_store(&self) -> Result<(), StoreError> {
            let caller = self.env().caller();
            if self.dotns_controllers.get(caller).unwrap_or(false) {
                return Ok(());
            }
            if !self.authorized_stores.get(caller).unwrap_or(false) {
                // We dont use require! here given the circular
                // dependency with the utils crate
                return Err(StoreError::NotAuthorised(caller));
            }

            Ok(())
        }

        fn ensure_unlocked(&self, user: H160, key: Key) -> Result<(), StoreError> {
            if self.locked_keys.get((user, key)).unwrap_or(false) {
                // We dont use require! here given the circular
                // dependency with the utils crate
                return Err(StoreError::KeyLocked { user, key });
            }

            Ok(())
        }

        fn push_value(&mut self, user: H160, value: String) {
            let mut list = self.values.get(user).unwrap_or_default();
            list.push(value);
            self.values.insert(user, &list);
        }

        fn get_or_empty(&self, user: H160, key: Key) -> String {
            self.store.get((user, key)).unwrap_or_default()
        }
    }

    impl StoreBase for Store {
        #[ink(message)]
        fn set_value(&mut self, key: Key, value: String) -> Result<(), StoreError> {
            let user = self.env().caller();
            self.ensure_unlocked(user, key)?;

            self.store.insert((user, key), &value);
            self.push_value(user, value.clone());

            self.env().emit_event(ValueStored { user, key, value });
            Ok(())
        }

        #[ink(message)]
        fn set_value_for(&mut self, user: H160, key: Key, value: String) -> Result<(), StoreError> {
            self.only_authorized_store()?;
            self.ensure_unlocked(user, key)?;

            self.store.insert((user, key), &value);
            self.push_value(user, value.clone());

            self.env().emit_event(ValueStored { user, key, value });

            let caller = self.env().caller();
            if self.dotns_controllers.get(caller).unwrap_or(false) {
                self.locked_keys.insert((user, key), &true);
                self.env().emit_event(KeyLockedPermanently {
                    user,
                    key,
                    locker: caller,
                });
            }

            Ok(())
        }

        #[ink(message)]
        fn get_value(&self, key: Key) -> String {
            let user = self.env().caller();
            self.get_or_empty(user, key)
        }

        #[ink(message)]
        fn get_value_for(&self, user: H160, key: Key) -> String {
            self.get_or_empty(user, key)
        }

        #[ink(message)]
        fn delete_value(&mut self, key: Key) -> Result<(), StoreError> {
            let user = self.env().caller();
            self.ensure_unlocked(user, key)?;

            self.store.remove((user, key));
            self.env().emit_event(ValueDeleted { user, key });
            Ok(())
        }

        #[ink(message)]
        fn has_value(&self, key: Key) -> bool {
            let user = self.env().caller();
            let v = self.store.get((user, key)).unwrap_or_default();
            !v.is_empty()
        }

        #[ink(message)]
        fn get_values(&self) -> Vec<String> {
            let user = self.env().caller();
            self.values.get(user).unwrap_or_default()
        }

        #[ink(message)]
        fn is_authorized(&self, store_address: H160) -> bool {
            self.authorized_stores.get(store_address).unwrap_or(false)
        }

        #[ink(message)]
        fn is_dotns_controller(&self, controller_address: H160) -> bool {
            self.dotns_controllers
                .get(controller_address)
                .unwrap_or(false)
        }

        #[ink(message)]
        fn is_locked(&self, user: H160, key: Key) -> bool {
            self.locked_keys.get((user, key)).unwrap_or(false)
        }

        #[ink(message)]
        fn authorize_store(&mut self, store_address: H160) -> Result<(), StoreError> {
            self.only_owner()?;
            self.authorized_stores.insert(store_address, &true);
            self.env().emit_event(StoreAuthorized {
                authorized_address: store_address,
            });
            Ok(())
        }

        #[ink(message)]
        fn unauthorize_store(&mut self, store_address: H160) -> Result<(), StoreError> {
            self.only_owner()?;
            self.authorized_stores.insert(store_address, &false);
            self.env().emit_event(StoreUnauthorized {
                unauthorized_address: store_address,
            });
            Ok(())
        }

        #[ink(message)]
        fn authorize_dotns_controller(
            &mut self,
            controller_address: H160,
        ) -> Result<(), StoreError> {
            self.only_owner()?;
            self.dotns_controllers.insert(controller_address, &true);
            self.env()
                .emit_event(DotnsControllerAuthorized { controller_address });
            Ok(())
        }

        #[ink(message)]
        fn unauthorize_dotns_controller(
            &mut self,
            controller_address: H160,
        ) -> Result<(), StoreError> {
            self.only_owner()?;
            self.dotns_controllers.insert(controller_address, &false);
            self.env()
                .emit_event(DotnsControllerUnauthorized { controller_address });
            Ok(())
        }
    }
}
