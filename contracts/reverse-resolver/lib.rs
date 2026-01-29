#![cfg_attr(not(feature = "std"), no_std, no_main)]

#[cfg(test)]
pub mod test_modules;

pub mod reverse_resolver;

#[ink::contract]
pub mod dotns_reverse_resolver {
    use crate::reverse_resolver::{BaseDotnsReverseResolver, ReverseResolverError};
    use dotns_utils::require;
    use ink::prelude::string::String;
    use ink::primitives::H160;
    use ink::storage::Mapping;

    /// Emitted when the registrar controller address is updated.
    ///
    /// # Fields
    ///
    /// * `old_registrar` - Previous registrar.
    /// * `new_registrar` - New registrar.
    #[ink(event)]
    pub struct RegistrarUpdated {
        #[ink(topic)]
        pub old_registrar: H160,
        #[ink(topic)]
        pub new_registrar: H160,
    }

    /// Emitted when a name is associated with an address.
    ///
    /// # Fields
    ///
    /// * `addr` - The address for which the reverse name is being set.
    /// * `name` - The human-readable name associated with the address.
    #[ink(event)]
    pub struct ReverseNameSet {
        #[ink(topic)]
        pub addr: H160,
        #[ink(topic)]
        pub name: String,
    }

    /// DotNS Reverse Resolver Contract
    ///
    /// Resolves an address to its associated .dot name.
    #[ink(storage)]
    pub struct DotnsReverseResolver {
        /// Contract owner with admin privileges.
        owner: H160,
        /// Address authorised to modify reverse name records.
        registrar: H160,
        /// Mapping from address to its reverse name.
        /// An empty string indicates that no reverse name is set.
        reverse_names: Mapping<H160, String>,
    }

    impl DotnsReverseResolver {
        /// Creates a new Reverse Resolver contract.
        #[ink(constructor)]
        pub fn new() -> Self {
            let caller = Self::env().caller();
            Self {
                owner: caller,
                registrar: H160::zero(),
                reverse_names: Mapping::default(),
            }
        }

        /// Returns the contract owner.
        ///
        /// # Returns
        ///
        /// * `H160` - The contract owner address.
        #[ink(message)]
        pub fn owner(&self) -> H160 {
            self.owner
        }

        /// Returns the current registrar address.
        ///
        /// # Returns
        ///
        /// * `H160` - The registrar address.
        #[ink(message)]
        pub fn registrar(&self) -> H160 {
            self.registrar
        }

        /// Returns the implementation version.
        ///
        /// # Returns
        ///
        /// * `String` - Current version string.
        #[ink(message)]
        pub fn version(&self) -> String {
            String::from("1.0.0")
        }

        /// Transfers ownership of the contract.
        ///
        /// Can only be called by the current owner.
        ///
        /// # Arguments
        ///
        /// * `new_owner` - The new owner address.
        ///
        /// # Errors
        ///
        /// * `NotOwner` - If the caller is not the current owner.
        #[ink(message)]
        pub fn transfer_ownership(&mut self, new_owner: H160) -> Result<(), ReverseResolverError> {
            require!(
                self.env().caller() == self.owner,
                ReverseResolverError::NotOwner
            );
            self.owner = new_owner;
            Ok(())
        }
    }

    impl Default for DotnsReverseResolver {
        fn default() -> Self {
            Self::new()
        }
    }

    impl BaseDotnsReverseResolver for DotnsReverseResolver {
        #[ink(message)]
        fn set_reverse_name(
            &mut self,
            addr: H160,
            name: String,
        ) -> Result<(), ReverseResolverError> {
            require!(
                self.env().caller() == self.registrar,
                ReverseResolverError::NotRegistrarController
            );

            self.reverse_names.insert(addr, &name);

            self.env().emit_event(ReverseNameSet { addr, name });

            Ok(())
        }

        #[ink(message)]
        fn name_of(&self, addr: H160) -> String {
            self.reverse_names.get(addr).unwrap_or_default()
        }

        #[ink(message)]
        fn update_registrar_controller(
            &mut self,
            new_registrar: H160,
        ) -> Result<(), ReverseResolverError> {
            require!(
                self.env().caller() == self.owner,
                ReverseResolverError::NotOwner
            );

            require!(
                new_registrar != H160::zero(),
                ReverseResolverError::InvalidRegistrarController
            );

            let old_registrar = self.registrar;
            self.registrar = new_registrar;

            self.env().emit_event(RegistrarUpdated {
                old_registrar,
                new_registrar,
            });

            Ok(())
        }
    }
}
