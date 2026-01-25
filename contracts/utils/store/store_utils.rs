//! Store Utilities
//!
//! Provides utilities for acquiring and managing Stores for contracts that require one.
//!
//! # Overview
//!
//! This module implements a three-tier resolution strategy for Store management:
//! 1. **Direct mapping:** A Store already exists and is mapped to the target owner.
//! 2. **Controller mapping:** A Store exists under the controller's address and must be migrated.
//! 3. **Fresh deployment:** No Store exists; deploy a new Store, authorise controllers, transfer ownership, and migrate the mapping.
//!
//! # Security Contact
//!
//! admin@parity.io

use crate::require;
use dotns_store::store_base::StoreBase;
use dotns_store::StoreRef;
use dotns_store_factory::base_store_factory::BaseStoreFactory;
use dotns_store_factory::StoreFactoryRef;
use ink::env::call::FromAddr;
use ink::prelude::vec::Vec;
use ink::primitives::H160;

/// Errors for Store utility operations.
#[derive(Debug, PartialEq, Eq)]
#[ink::scale_derive(Encode, Decode, TypeInfo)]
pub enum StoreUtilsError {
    /// Occurs when Store deployment fails.
    DeploymentFailed,

    /// Occurs when ownership transfer fails.
    TransferFailed,

    /// Occurs when authorising a controller fails.
    AuthorizationFailed,

    /// Occurs when an invalid ownership transfer is detected.
    InvalidTransfer { owner: H160 },

    /// Occurs when a cross-contract call fails.
    CallFailed,

    /// Occurs when a store is already mapped.
    AlreadyMapped { owner: H160 },
}

/// Returns the Store for `owner`, deploying or migrating one if required.
///
/// This function handles all three Store acquisition scenarios:
///
/// 1. **Direct mapping:** A Store exists for `owner` and is returned immediately.
/// 2. **Controller migration:** A Store exists for the calling controller; ownership and mapping are migrated to `owner`.
/// 3. **Fresh deployment:** No Store exists; deploys a new Store, authorises the controllers, transfers ownership to `owner`, and migrates the mapping.
///
/// # Reentrancy Considerations
///
/// No explicit reentrancy guard is applied. The deployed Store is not expected to call back into this function.
/// Callers must ensure the Store implementation does not introduce unexpected callbacks. Both StoreFactory and Store contracts are non-upgradeable and do not make external calls that could create reentrancy risks.
///
/// # Parameters
///
/// * `factory` - Reference to the StoreFactory contract used to resolve or deploy Stores.
/// * `controllers` - Addresses to be authorised for DotNS operations.
/// * `owner` - The target Store owner address.
/// * `caller` - The address of the calling contract.
///
/// # Returns
///
/// Returns the resolved or newly deployed Store address.
///
/// # Errors
///
/// Returns `StoreUtilsError` if any operation fails during deployment, authorisation, or transfer.
pub fn get_or_create_store(
    factory: &mut StoreFactoryRef,
    controllers: Vec<H160>,
    owner: H160,
    caller: H160,
) -> Result<H160, StoreUtilsError> {
    let existing = factory.get_deployed_store(owner);
    if existing != H160::zero() {
        return Ok(existing);
    }

    let controller_mapped = factory.get_deployed_store(caller);

    require!(
        controller_mapped == H160::zero(),
        StoreUtilsError::AlreadyMapped { owner }
    );

    let store_addr = factory
        .deploy()
        .map_err(|_| StoreUtilsError::DeploymentFailed)?;

    require!(
        store_addr != H160::zero(),
        StoreUtilsError::DeploymentFailed
    );

    let mut store_ref = StoreRef::from_addr(store_addr);

    for controller in controllers {
        store_ref
            .authorize_dotns_controller(controller)
            .map_err(|_| StoreUtilsError::AuthorizationFailed)?;
    }

    store_ref
        .transfer_ownership(owner)
        .map_err(|_| StoreUtilsError::TransferFailed)?;

    factory
        .transfer_ownership(owner)
        .map_err(|_| StoreUtilsError::TransferFailed)?;

    Ok(store_addr)
}

/// Checks whether a Store exists for a given owner.
///
/// Performs a read-only lookup against the factory without modifying state.
///
/// # Parameters
///
/// * `factory` - Reference to the StoreFactory contract to query.
/// * `owner` - The owner address to check.
///
/// # Returns
///
/// Returns `true` if a Store is mapped to `owner`, `false` otherwise.
pub fn has_store(factory: &StoreFactoryRef, owner: H160) -> bool {
    let existing = factory.get_deployed_store(owner);
    existing != H160::zero()
}

/// Returns the Store address for an owner without deploying.
///
/// Returns the zero address if no Store exists. Use `has_store` for boolean checks.
///
/// # Parameters
///
/// * `factory` - Reference to the StoreFactory contract to query.
/// * `owner` - The owner address to look up.
///
/// # Returns
///
/// The Store address, or zero if none exists.
pub fn get_store(factory: &StoreFactoryRef, owner: H160) -> H160 {
    factory.get_deployed_store(owner)
}
