use crate::base_store_factory::BaseStoreFactory;
use crate::dotns_store_factory::StoreFactory;
use dotns_store::dotns_store::StoreRef;
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
fn test_initialization() {
    let acc = accounts();
    set_caller(acc.alice);

    let code_hash = ink::primitives::H256::from([1u8; 32]);
    let factory = StoreFactory::new(code_hash);

    assert_eq!(factory.store_code_hash(), code_hash);
}

#[ink::test]
fn test_deploy_registers_store() {
    let acc = accounts();
    let mut factory = setup_factory();

    let store = factory.deploy().unwrap();

    assert_ne!(store, H160::zero());
    assert_eq!(factory.get_deployed_store(acc.alice), store);
}

#[ink::test]
fn test_get_deployed_store_returns_zero_for_unknown() {
    let acc = accounts();
    let factory = setup_factory();

    assert_eq!(factory.get_deployed_store(acc.charlie), H160::zero());
}

#[ink::test]
fn test_transfer_ownership() {
    let acc = accounts();
    let mut factory = setup_factory();

    let store = factory.deploy().unwrap();

    factory.transfer_ownership(acc.bob).unwrap();

    assert_eq!(factory.get_deployed_store(acc.alice), H160::zero());
    assert_eq!(factory.get_deployed_store(acc.bob), store);
}
