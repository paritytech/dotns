use crate::dotns_store::Store;
use crate::store_base::{StoreBase, StoreError};
use ink::primitives::H160;

fn accounts() -> ink::env::test::DefaultAccounts {
    ink::env::test::default_accounts()
}

fn set_caller(account: H160) {
    ink::env::test::set_caller(account);
}

fn setup_store() -> Store {
    let acc = accounts();
    set_caller(acc.alice);
    Store::new()
}

fn make_key(s: &str) -> [u8; 32] {
    let mut key = [0u8; 32];
    let bytes = s.as_bytes();
    let len = bytes.len().min(32);
    key[..len].copy_from_slice(&bytes[..len]);
    key
}

#[ink::test]
fn test_owner_only_functions_revert_not_owner() {
    let acc = accounts();
    let mut store = setup_store();

    set_caller(acc.bob);

    assert!(matches!(
        store.transfer_ownership(acc.charlie),
        Err(StoreError::NotAuthorised(_))
    ));
}

#[ink::test]
fn test_set_value_for_reverts_unauthorized() {
    let acc = accounts();
    let mut store = setup_store();

    set_caller(acc.bob);
    let result = store.set_value_for(acc.charlie, make_key("test"), "ipfs://QmTest".to_string());

    assert!(matches!(result, Err(StoreError::NotAuthorised(_))));
}

#[ink::test]
fn test_locked_key_reverts_modification() {
    let acc = accounts();
    let mut store = setup_store();
    let key = make_key("locked");

    store.authorize_dotns_controller(acc.bob).unwrap();

    set_caller(acc.bob);
    store
        .set_value_for(acc.charlie, key, "ipfs://QmLocked".to_string())
        .unwrap();

    set_caller(acc.charlie);
    let result = store.set_value(key, "ipfs://QmNew".to_string());

    assert!(matches!(result, Err(StoreError::KeyLocked { .. })));
}
