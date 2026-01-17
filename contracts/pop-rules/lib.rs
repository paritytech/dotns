#![cfg_attr(not(feature = "std"), no_std, no_main)]

#[macro_use]
mod utils;
pub mod popbase;

#[cfg(test)]
mod test_modules;

#[ink::contract]
pub mod pop_rules {
    use crate::popbase::{
        Classification, PopRulesBase, PopRulesError, PopStatus, PriceWithMeta, Reservation,
        ReservationStatus,
    };
    use ink::prelude::string::String;
    use ink::prelude::vec::Vec;
    use ink::storage::Mapping;
    use ink::{H160, H256};

    /// Maximum time a base name can be reserved (12 weeks in seconds).
    const MAX_RESERVATION_TIME: u64 = 12 * 7 * 24 * 60 * 60;

    /// Emitted when a base name receives a reservation.
    #[ink(event)]
    pub struct BaseNameReserved {
        /// The digit-stripped label receiving reservation.
        #[ink(topic)]
        pub base_name: String,
        /// Address obtaining the reservation right.
        #[ink(topic)]
        pub owner: H160,
        /// Timestamp when the reservation expires.
        pub expires: u64,
    }

    /// Emitted when the registry address is updated.
    #[ink(event)]
    pub struct RegistryUpdated {
        /// Currently set registry address.
        #[ink(topic)]
        pub old_registry: H160,
        /// New address to set.
        #[ink(topic)]
        pub new_registry: H160,
    }

    /// Emitted when a user's PoP status is updated.
    #[ink(event)]
    pub struct UserPopStatusSet {
        /// Address of the user.
        #[ink(topic)]
        pub user: H160,
        /// New PoP tier assigned.
        pub status: PopStatus,
    }

    /// Emitted when the contract code is upgraded.
    #[ink(event)]
    pub struct Upgraded {
        /// New code hash.
        #[ink(topic)]
        pub code_hash: [u8; 32],
    }

    /// Implements DotNS pricing with PoP-tier validation and base-name reservations.
    ///
    /// # Storage Compatibility (Upgrades)
    ///
    /// When upgrading this contract via `set_code`:
    /// - Do not reorder existing fields
    /// - Do not change field types
    /// - Add new fields at the end only
    #[ink(storage)]
    pub struct PopRules {
        /// Contract owner address.
        owner: H160,
        /// Wei price for names with 9 characters and up.
        starting_price: u128,
        /// Tracks PoP status per user/profile.
        user_pop_status: Mapping<H160, PopStatus>,
        /// Active reservations for base names.
        reservations: Mapping<String, Reservation>,
        /// Authorized registry controller address.
        registry_controller: H160,
    }

    impl PopRules {
        /// Initializes the contract with pricing parameters.
        ///
        /// # Arguments
        ///
        /// * `starting_price` - Base price for NoStatus users.
        #[ink(constructor)]
        pub fn new(starting_price: u128) -> Self {
            Self {
                owner: Self::env().caller(),
                starting_price,
                user_pop_status: Mapping::default(),
                reservations: Mapping::default(),
                registry_controller: H160::zero(),
            }
        }

        /// Returns the contract owner.
        #[ink(message)]
        pub fn owner(&self) -> H160 {
            self.owner
        }

        /// Returns the registry controller address.
        #[ink(message)]
        pub fn registry_controller(&self) -> H160 {
            self.registry_controller
        }

        /// Returns the starting price.
        #[ink(message)]
        pub fn starting_price(&self) -> u128 {
            self.starting_price
        }

        /// Returns implementation version.
        #[ink(message)]
        pub fn version(&self) -> String {
            String::from("1.1.0")
        }

        /// Modifies the code which is used to execute calls to this contract address.
        ///
        /// This effectively upgrades the contract to a new implementation.
        ///
        /// # Arguments
        ///
        /// * `code_hash` - The code hash of the new implementation.
        ///
        /// # Errors
        ///
        /// Returns `NotOwner` if the caller is not the contract owner.
        ///
        /// # Storage Compatibility
        ///
        /// The new implementation must have compatible storage layout.
        /// Do not change the order or types of existing storage fields.
        #[ink(message)]
        pub fn set_code(&mut self, code_hash: [u8; 32]) -> Result<(), PopRulesError> {
            self.only_owner()?;

            self.env().emit_event(Upgraded { code_hash });

            let hash = H256::from(code_hash);
            ink::env::set_code_hash::<ink::env::DefaultEnvironment>(&hash).unwrap_or_else(|err| {
                panic!(
                    "Failed to set_code_hash to {:?} due to {:?}",
                    code_hash, err
                )
            });
            Ok(())
        }

        /// Enforces base name reservation rules.
        ///
        /// # Arguments
        ///
        /// * `name` - Domain label.
        /// * `user_address` - Registering user.
        fn enforce_reservation_rules(
            &self,
            name: &String,
            user_address: H160,
        ) -> Result<(), PopRulesError> {
            let base_name = Self::strip_digits(name);
            let reservation = self.reservations.get(&base_name).unwrap_or_default();
            let current_time = self.env().block_timestamp();

            let is_reserved =
                reservation.owner != H160::zero() && reservation.expires > current_time;
            let is_owner = reservation.owner == user_address;

            require!(
                !is_reserved || is_owner,
                PopRulesError::PopError(String::from(
                    "Base name reserved for original Lite registrant"
                ))
            );

            Ok(())
        }

        /// Ensures the caller is the contract owner.
        fn only_owner(&self) -> Result<(), PopRulesError> {
            require!(self.env().caller() == self.owner, PopRulesError::NotOwner);
            Ok(())
        }

        /// Ensures the caller is the authorized registry controller.
        fn only_registry(&self) -> Result<(), PopRulesError> {
            require!(
                self.env().caller() == self.registry_controller,
                PopRulesError::NotRegistry
            );
            Ok(())
        }

        /// Counts the number of Unicode characters in a string.
        fn strlen(s: &String) -> usize {
            s.chars().count()
        }

        /// Counts trailing digits in a string.
        ///
        /// # Arguments
        ///
        /// * `label` - String to analyze.
        ///
        /// # Returns
        ///
        /// Number of trailing digits (0-9).
        fn count_trailing_digits(label: &String) -> usize {
            let bytes = label.as_bytes();
            let mut digit_count: usize = 0;

            for i in (0..bytes.len()).rev() {
                if bytes[i] >= b'0' && bytes[i] <= b'9' {
                    digit_count += 1;
                } else {
                    break;
                }
            }

            digit_count
        }

        /// Strips trailing digits from a name.
        ///
        /// # Arguments
        ///
        /// * `name` - Domain label.
        ///
        /// # Returns
        ///
        /// Name without trailing digits.
        fn strip_digits(name: &String) -> String {
            let bytes = name.as_bytes();
            let mut end_position = bytes.len();

            while end_position > 0
                && bytes[end_position - 1] >= b'0'
                && bytes[end_position - 1] <= b'9'
            {
                end_position -= 1;
            }

            let output: Vec<u8> = bytes[..end_position].to_vec();

            String::from_utf8(output).unwrap_or_default()
        }
    }

    impl PopRulesBase for PopRules {
        #[ink(message)]
        fn set_user_pop_status(&mut self, status: PopStatus) {
            let caller = self.env().caller();
            self.user_pop_status.insert(caller, &status);
            self.env().emit_event(UserPopStatusSet {
                user: caller,
                status,
            });
        }

        #[ink(message)]
        fn get_user_pop_status(&self, user: H160) -> PopStatus {
            self.user_pop_status.get(user).unwrap_or_default()
        }

        #[ink(message)]
        fn classify_name(&self, name: String) -> Result<Classification, PopRulesError> {
            let total_length = Self::strlen(&name);
            let trailing_digits = Self::count_trailing_digits(&name);

            require!(trailing_digits <= 2, PopRulesError::TooManyTrailingDigits);

            let base_length = total_length - trailing_digits;

            if base_length <= 5 {
                return Ok(Classification {
                    requirement: PopStatus::Reserved,
                    message: String::from("Reserved for Governance"),
                });
            }

            if base_length >= 6 && base_length <= 8 {
                if trailing_digits == 2 {
                    return Ok(Classification {
                        requirement: PopStatus::PopLite,
                        message: String::from("Requires Light personhood verification"),
                    });
                }
                return Ok(Classification {
                    requirement: PopStatus::PopFull,
                    message: String::from("Requires Full personhood verification"),
                });
            }

            if trailing_digits == 2 {
                return Ok(Classification {
                    requirement: PopStatus::NoStatus,
                    message: String::from("Available to all"),
                });
            }

            Ok(Classification {
                requirement: PopStatus::PopFull,
                message: String::from("Requires Full personhood verification"),
            })
        }

        #[ink(message)]
        fn reserve_base_name(
            &mut self,
            name: String,
            user_address: H160,
        ) -> Result<(), PopRulesError> {
            self.only_registry()?;

            let classification = self.classify_name(name.clone())?;

            require!(
                classification.requirement == PopStatus::PopLite,
                PopRulesError::NotLiteEligible
            );

            let stripped_base = Self::strip_digits(&name);
            let existing_reservation = self.reservations.get(&stripped_base);

            if existing_reservation.is_none() || existing_reservation.unwrap().owner == H160::zero()
            {
                let expiry_time = self.env().block_timestamp() + MAX_RESERVATION_TIME;

                self.reservations.insert(
                    stripped_base.clone(),
                    &Reservation {
                        owner: user_address,
                        expires: expiry_time,
                    },
                );

                self.env().emit_event(BaseNameReserved {
                    base_name: stripped_base,
                    owner: user_address,
                    expires: expiry_time,
                });
            }

            Ok(())
        }

        #[ink(message)]
        fn update_registry(&mut self, new_registry: H160) -> Result<(), PopRulesError> {
            self.only_owner()?;

            let old_registry = self.registry_controller;

            self.env().emit_event(RegistryUpdated {
                old_registry,
                new_registry,
            });

            self.registry_controller = new_registry;

            Ok(())
        }

        #[ink(message)]
        fn is_base_name(&self, base_name: String) -> bool {
            Self::count_trailing_digits(&base_name) == 0
        }

        #[ink(message)]
        fn get_base_name_reservation(&self, base_name: String) -> Reservation {
            self.reservations.get(&base_name).unwrap_or_default()
        }

        #[ink(message)]
        fn is_base_name_reserved(&self, base_name: String) -> ReservationStatus {
            let reservation = self.reservations.get(&base_name).unwrap_or_default();
            let current_time = self.env().block_timestamp();

            let is_reserved =
                reservation.owner != H160::zero() && reservation.expires > current_time;

            ReservationStatus {
                is_reserved,
                owner: reservation.owner,
                expires: reservation.expires,
            }
        }

        #[ink(message)]
        fn price_with_check(
            &self,
            name: String,
            user_address: H160,
        ) -> Result<PriceWithMeta, PopRulesError> {
            self.enforce_reservation_rules(&name, user_address)?;

            let classification = self.classify_name(name.clone())?;
            let user_status = self.user_pop_status.get(user_address).unwrap_or_default();

            let price = if user_status == PopStatus::NoStatus {
                self.price(name.clone())
            } else {
                0
            };

            let metadata = PriceWithMeta {
                price,
                status: classification.requirement,
                user_status,
                message: classification.message.clone(),
            };

            require!(
                classification.requirement != PopStatus::Reserved,
                PopRulesError::PopError(classification.message)
            );

            if classification.requirement == PopStatus::PopFull {
                require!(
                    user_status == PopStatus::PopFull,
                    PopRulesError::PopError(String::from("Requires Full Personhood verification"))
                );
            } else if classification.requirement == PopStatus::PopLite {
                require!(
                    user_status == PopStatus::PopLite || user_status == PopStatus::PopFull,
                    PopRulesError::PopError(String::from("Requires Personhood Lite verification"))
                );
            } else {
                let trailing_digits = Self::count_trailing_digits(&name);
                require!(
                    trailing_digits != 0 || user_status != PopStatus::PopLite,
                    PopRulesError::PopError(String::from(
                        "Personhood Lite cannot register base names"
                    ))
                );
            }

            Ok(metadata)
        }

        #[ink(message)]
        fn price_without_check(
            &self,
            name: String,
            user_address: H160,
        ) -> Result<PriceWithMeta, PopRulesError> {
            let classification = self.classify_name(name.clone())?;
            let user_status = self.user_pop_status.get(user_address).unwrap_or_default();

            let price = if user_status == PopStatus::NoStatus {
                self.price(name.clone())
            } else {
                0
            };

            let mut metadata = PriceWithMeta {
                price,
                status: classification.requirement,
                user_status,
                message: classification.message,
            };

            let base_name = Self::strip_digits(&name);
            let reservation = self.reservations.get(&base_name).unwrap_or_default();
            let current_time = self.env().block_timestamp();

            if reservation.owner != H160::zero()
                && reservation.expires > current_time
                && reservation.owner != user_address
            {
                metadata.message = String::from("Base name reserved for original Lite registrant");
                metadata.status = PopStatus::Reserved;
            }

            Ok(metadata)
        }

        #[ink(message)]
        fn price(&self, name: String) -> u128 {
            let name_length = Self::strlen(&name);

            if name_length < 9 {
                return 0;
            }

            if name_length >= 15 {
                return self.starting_price / 2;
            }

            self.starting_price * (15 - name_length) as u128
        }
    }
}
