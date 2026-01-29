#![cfg_attr(not(feature = "std"), no_std, no_main)]

#[cfg(test)]
pub mod test_modules;

pub mod registrar;

#[ink::contract]
pub mod dotns_registrar {
    use crate::registrar::{BaseDotnsRegistrar, RegistrarError};
    use dotns_utils::require;
    use ink::prelude::string::String;
    use ink::primitives::{H160, U256};
    use ink::storage::Mapping;

    /// Emitted when a name is registered.
    ///
    /// # Fields
    ///
    /// * `id` - Token identifier.
    /// * `owner` - Owner of the name.
    #[ink(event)]
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
    #[ink(event)]
    pub struct ControllerAdded {
        #[ink(topic)]
        pub controller: H160,
    }

    /// Emitted when a controller is removed.
    ///
    /// # Fields
    ///
    /// * `controller` - Address whose controller permissions were revoked.
    #[ink(event)]
    pub struct ControllerRemoved {
        #[ink(topic)]
        pub controller: H160,
    }

    /// Emitted when a token is transferred.
    ///
    /// # Fields
    ///
    /// * `from` - The sender address (None for mints).
    /// * `to` - The recipient address (None for burns).
    /// * `token_id` - The token identifier.
    #[ink(event)]
    pub struct Transfer {
        #[ink(topic)]
        pub from: Option<H160>,
        #[ink(topic)]
        pub to: Option<H160>,
        #[ink(topic)]
        pub token_id: U256,
    }

    /// Emitted when an approval is set.
    ///
    /// # Fields
    ///
    /// * `owner` - The token owner.
    /// * `approved` - The approved address (None to clear).
    /// * `token_id` - The token identifier.
    #[ink(event)]
    pub struct Approval {
        #[ink(topic)]
        pub owner: H160,
        #[ink(topic)]
        pub approved: Option<H160>,
        #[ink(topic)]
        pub token_id: U256,
    }

    /// Emitted when an operator approval is set.
    ///
    /// # Fields
    ///
    /// * `owner` - The token owner.
    /// * `operator` - The operator address.
    /// * `approved` - Whether the operator is approved.
    #[ink(event)]
    pub struct ApprovalForAll {
        #[ink(topic)]
        pub owner: H160,
        #[ink(topic)]
        pub operator: H160,
        pub approved: bool,
    }

    /// ERC721 specific errors.
    #[derive(Debug, PartialEq, Eq)]
    #[ink::scale_derive(Encode, Decode, TypeInfo)]
    pub enum ERC721Error {
        /// Token does not exist.
        TokenNotFound,
        /// Caller is not owner nor approved.
        NotOwnerOrApproved,
        /// Transfer to zero address.
        TransferToZeroAddress,
        /// Approval to current owner.
        ApprovalToCurrentOwner,
    }

    /// DotNS Base Registrar Contract
    ///
    /// ERC721-backed ownership for DotNS names with controller-gated registration.
    #[ink(storage)]
    pub struct DotnsRegistrar {
        /// Contract owner with admin privileges.
        owner: H160,
        /// Authorised controllers that can register names.
        controllers: Mapping<H160, bool>,
        /// Token owners mapping (token_id -> owner).
        token_owners: Mapping<U256, H160>,
        /// Balance of each owner (owner -> count).
        balances: Mapping<H160, U256>,
        /// Token approvals (token_id -> approved).
        token_approvals: Mapping<U256, H160>,
        /// Operator approvals (owner -> operator -> approved).
        operator_approvals: Mapping<(H160, H160), bool>,
        /// Token name.
        name: String,
        /// Token symbol.
        symbol: String,
    }

    impl DotnsRegistrar {
        /// Creates a new DotNS Registrar contract.
        ///
        /// # Arguments
        ///
        /// * `name` - The token collection name.
        /// * `symbol` - The token collection symbol.
        #[ink(constructor)]
        pub fn new(name: String, symbol: String) -> Self {
            let caller = Self::env().caller();
            Self {
                owner: caller,
                controllers: Mapping::default(),
                token_owners: Mapping::default(),
                balances: Mapping::default(),
                token_approvals: Mapping::default(),
                operator_approvals: Mapping::default(),
                name,
                symbol,
            }
        }

        /// Returns the token collection name.
        ///
        /// # Returns
        ///
        /// * `String` - The token name.
        #[ink(message)]
        pub fn name(&self) -> String {
            self.name.clone()
        }

        /// Returns the token collection symbol.
        ///
        /// # Returns
        ///
        /// * `String` - The token symbol.
        #[ink(message)]
        pub fn symbol(&self) -> String {
            self.symbol.clone()
        }

        /// Returns the number of tokens owned by an address.
        ///
        /// # Arguments
        ///
        /// * `owner` - The address to query.
        ///
        /// # Returns
        ///
        /// * `U256` - The number of tokens owned.
        #[ink(message)]
        pub fn balance_of(&self, owner: H160) -> U256 {
            self.balances.get(owner).unwrap_or(U256::zero())
        }

        /// Returns the owner of a token.
        ///
        /// # Arguments
        ///
        /// * `token_id` - The token identifier.
        ///
        /// # Returns
        ///
        /// * `Option<H160>` - The owner address if the token exists.
        #[ink(message)]
        pub fn owner_of(&self, token_id: U256) -> Option<H160> {
            self.token_owners.get(token_id)
        }

        /// Returns whether an address is an authorised controller.
        ///
        /// # Arguments
        ///
        /// * `controller` - The address to check.
        ///
        /// # Returns
        ///
        /// * `bool` - True if the address is an authorised controller.
        #[ink(message)]
        pub fn is_controller(&self, controller: H160) -> bool {
            self.controllers.get(controller).unwrap_or(false)
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
        pub fn transfer_ownership(&mut self, new_owner: H160) -> Result<(), RegistrarError> {
            require!(self.env().caller() == self.owner, RegistrarError::NotOwner);
            self.owner = new_owner;
            Ok(())
        }

        /// Approves an address to manage a specific token.
        ///
        /// # Arguments
        ///
        /// * `to` - The address to approve.
        /// * `token_id` - The token identifier.
        ///
        /// # Errors
        ///
        /// * `TokenNotFound` - If the token does not exist.
        /// * `NotOwnerOrApproved` - If caller is not owner or operator.
        /// * `ApprovalToCurrentOwner` - If approving the current owner.
        #[ink(message)]
        pub fn approve(&mut self, to: H160, token_id: U256) -> Result<(), ERC721Error> {
            let owner = self
                .token_owners
                .get(token_id)
                .ok_or(ERC721Error::TokenNotFound)?;
            let caller = self.env().caller();

            require!(to != owner, ERC721Error::ApprovalToCurrentOwner);

            require!(
                caller == owner || self.is_approved_for_all(owner, caller),
                ERC721Error::NotOwnerOrApproved
            );

            self.token_approvals.insert(token_id, &to);

            self.env().emit_event(Approval {
                owner,
                approved: Some(to),
                token_id,
            });

            Ok(())
        }

        /// Returns the approved address for a token.
        ///
        /// # Arguments
        ///
        /// * `token_id` - The token identifier.
        ///
        /// # Returns
        ///
        /// * `Option<H160>` - The approved address if set.
        #[ink(message)]
        pub fn get_approved(&self, token_id: U256) -> Option<H160> {
            self.token_approvals.get(token_id)
        }

        /// Sets approval for an operator to manage all caller's tokens.
        ///
        /// # Arguments
        ///
        /// * `operator` - The operator address.
        /// * `approved` - Whether to approve or revoke.
        #[ink(message)]
        pub fn set_approval_for_all(&mut self, operator: H160, approved: bool) {
            let caller = self.env().caller();
            self.operator_approvals
                .insert((caller, operator), &approved);

            self.env().emit_event(ApprovalForAll {
                owner: caller,
                operator,
                approved,
            });
        }

        /// Returns whether an operator is approved for all tokens of an owner.
        ///
        /// # Arguments
        ///
        /// * `owner` - The token owner.
        /// * `operator` - The operator address.
        ///
        /// # Returns
        ///
        /// * `bool` - True if the operator is approved.
        #[ink(message)]
        pub fn is_approved_for_all(&self, owner: H160, operator: H160) -> bool {
            self.operator_approvals
                .get((owner, operator))
                .unwrap_or(false)
        }

        /// Transfers a token from one address to another.
        ///
        /// # Arguments
        ///
        /// * `from` - The current owner.
        /// * `to` - The recipient.
        /// * `token_id` - The token identifier.
        ///
        /// # Errors
        ///
        /// * `TokenNotFound` - If the token does not exist.
        /// * `NotOwnerOrApproved` - If caller lacks permission.
        /// * `TransferToZeroAddress` - If transferring to zero address.
        #[ink(message)]
        pub fn transfer_from(
            &mut self,
            from: H160,
            to: H160,
            token_id: U256,
        ) -> Result<(), ERC721Error> {
            require!(to != H160::zero(), ERC721Error::TransferToZeroAddress);

            let owner = self
                .token_owners
                .get(token_id)
                .ok_or(ERC721Error::TokenNotFound)?;
            require!(owner == from, ERC721Error::NotOwnerOrApproved);

            let caller = self.env().caller();
            require!(
                self.is_approved_or_owner(caller, token_id),
                ERC721Error::NotOwnerOrApproved
            );

            self.transfer_internal(from, to, token_id);

            Ok(())
        }

        /// Safely transfers a token from one address to another.
        ///
        /// # Note
        ///
        /// In ink!, receiver checks are not standard. This behaves
        /// identically to `transfer_from`.
        ///
        /// # Arguments
        ///
        /// * `from` - The current owner.
        /// * `to` - The recipient.
        /// * `token_id` - The token identifier.
        ///
        /// # Errors
        ///
        /// * `TokenNotFound` - If the token does not exist.
        /// * `NotOwnerOrApproved` - If caller lacks permission.
        /// * `TransferToZeroAddress` - If transferring to zero address.
        #[ink(message)]
        pub fn safe_transfer_from(
            &mut self,
            from: H160,
            to: H160,
            token_id: U256,
        ) -> Result<(), ERC721Error> {
            self.transfer_from(from, to, token_id)
        }

        /// Safely transfers a token with additional data.
        ///
        /// # Note
        ///
        /// In ink!, receiver checks are not standard. This behaves
        /// identically to `transfer_from`. Data parameter is ignored.
        ///
        /// # Arguments
        ///
        /// * `from` - The current owner.
        /// * `to` - The recipient.
        /// * `token_id` - The token identifier.
        /// * `_data` - Additional data (ignored).
        ///
        /// # Errors
        ///
        /// * `TokenNotFound` - If the token does not exist.
        /// * `NotOwnerOrApproved` - If caller lacks permission.
        /// * `TransferToZeroAddress` - If transferring to zero address.
        #[ink(message)]
        pub fn safe_transfer_from_with_data(
            &mut self,
            from: H160,
            to: H160,
            token_id: U256,
            _data: ink::prelude::vec::Vec<u8>,
        ) -> Result<(), ERC721Error> {
            self.transfer_from(from, to, token_id)
        }

        /// Checks if a token exists.
        ///
        /// # Arguments
        ///
        /// * `token_id` - The token identifier.
        ///
        /// # Returns
        ///
        /// * `bool` - True if the token exists.
        fn exists(&self, token_id: U256) -> bool {
            self.token_owners.contains(token_id)
        }

        /// Checks if spender is owner or approved for a token.
        ///
        /// # Arguments
        ///
        /// * `spender` - The address to check.
        /// * `token_id` - The token identifier.
        ///
        /// # Returns
        ///
        /// * `bool` - True if spender is owner or approved.
        fn is_approved_or_owner(&self, spender: H160, token_id: U256) -> bool {
            let owner = match self.token_owners.get(token_id) {
                Some(o) => o,
                None => return false,
            };

            spender == owner
                || self.get_approved(token_id) == Some(spender)
                || self.is_approved_for_all(owner, spender)
        }

        /// Internal transfer logic.
        ///
        /// # Arguments
        ///
        /// * `from` - The sender.
        /// * `to` - The recipient.
        /// * `token_id` - The token identifier.
        fn transfer_internal(&mut self, from: H160, to: H160, token_id: U256) {
            self.token_approvals.remove(token_id);

            let from_balance = self.balances.get(from).unwrap_or(U256::zero());
            self.balances.insert(from, &(from_balance - U256::from(1)));

            let to_balance = self.balances.get(to).unwrap_or(U256::zero());
            self.balances.insert(to, &(to_balance + U256::from(1)));

            self.token_owners.insert(token_id, &to);

            self.env().emit_event(Transfer {
                from: Some(from),
                to: Some(to),
                token_id,
            });
        }

        /// Mints a new token to the specified owner.
        ///
        /// # Arguments
        ///
        /// * `to` - The address to mint the token to.
        /// * `token_id` - The token identifier.
        fn mint(&mut self, to: H160, token_id: U256) {
            self.token_owners.insert(token_id, &to);

            let balance = self.balances.get(to).unwrap_or(U256::zero());
            self.balances.insert(to, &(balance + U256::from(1)));

            self.env().emit_event(Transfer {
                from: None,
                to: Some(to),
                token_id,
            });
        }
    }

    impl BaseDotnsRegistrar for DotnsRegistrar {
        #[ink(message)]
        fn available(&self, id: U256) -> bool {
            !self.exists(id)
        }
        #[ink(message)]
        fn register(&mut self, id: U256, owner: H160) -> Result<(), RegistrarError> {
            let caller = self.env().caller();

            require!(
                self.is_controller(caller),
                RegistrarError::NotController { caller }
            );

            require!(
                self.available(id),
                RegistrarError::NameNotAvailable { token_id: id }
            );

            self.mint(owner, id);

            self.env().emit_event(NameRegistered { id, owner });

            Ok(())
        }

        #[ink(message)]
        fn add_controller(&mut self, controller: H160) -> Result<(), RegistrarError> {
            require!(self.env().caller() == self.owner, RegistrarError::NotOwner);

            self.controllers.insert(controller, &true);

            self.env().emit_event(ControllerAdded { controller });

            Ok(())
        }

        #[ink(message)]
        fn remove_controller(&mut self, controller: H160) -> Result<(), RegistrarError> {
            require!(self.env().caller() == self.owner, RegistrarError::NotOwner);

            self.controllers.remove(controller);

            self.env().emit_event(ControllerRemoved { controller });

            Ok(())
        }
    }
}
