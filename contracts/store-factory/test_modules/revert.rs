use crate::base_store_factory::{BaseStoreFactory, FactoryError};
use crate::dotns_store_factory::StoreFactory;
use dotns_store::StoreRef;
use ink::primitives::H160;

fn accounts() -> ink::env::test::DefaultAccounts {
    ink::env::test::default_accounts()
}

fn set_caller(account: H160) {
    ink::env::test::set_caller(account);
}

fn setup_factory() -> StoreFactory {
    let acc = accounts();
    set_caller(acc.alice);
    let code_hash = ink::env::test::upload_code::<ink::env::DefaultEnvironment, StoreRef>();

    StoreFactory::new(code_hash)
}

#[ink::test]
fn test_deploy_already_deployed() {
    let mut factory = setup_factory();

    let first_store = factory.deploy().unwrap();
    let result = factory.deploy();

    assert!(matches!(
        result,
        Err(FactoryError::AlreadyDeployed(addr)) if addr == first_store
    ));
}

#[ink::test]
fn test_transfer_no_store() {
    let acc = accounts();
    let mut factory = setup_factory();

    let result = factory.transfer_ownership(acc.bob);
    assert!(matches!(
        result,
        Err(FactoryError::InvalidTransfer(addr)) if addr == acc.alice
    ));
}

#[ink::test]
fn test_transfer_to_existing_owner() {
    let acc = accounts();
    let mut factory = setup_factory();

    factory.deploy().unwrap();

    set_caller(acc.bob);
    factory.deploy().unwrap();

    set_caller(acc.alice);
    let result = factory.transfer_ownership(acc.bob);

    assert!(matches!(
        result,
        Err(FactoryError::InvalidTransfer(addr)) if addr == acc.bob
    ));
}
