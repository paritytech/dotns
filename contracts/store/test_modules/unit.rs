use crate::dotns_store::Store;
use crate::store_base::StoreBase;
use ink::prelude::string::{String, ToString};
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
fn test_initialization() {
    let acc = accounts();
    let store = setup_store();

    assert_eq!(store.owner(), acc.alice);
}

#[ink::test]
fn test_set_and_get() {
    let mut store = setup_store();
    let key = make_key("mykey");
    let value = "ipfs://QmTest123".to_string();

    store.set_value(key, value.clone()).unwrap();

    assert_eq!(store.get_value(key), value);
}

#[ink::test]
fn test_get_nonexistent_returns_empty() {
    let store = setup_store();

    assert_eq!(store.get_value(make_key("nonexistent")), String::new());
}

#[ink::test]
fn test_delete_value() {
    let mut store = setup_store();
    let key = make_key("toremove");

    store.set_value(key, "ipfs://QmTest".to_string()).unwrap();
    assert!(store.has_value(key));

    store.delete_value(key).unwrap();
    assert!(!store.has_value(key));
}

#[ink::test]
fn test_transfer_ownership() {
    let acc = accounts();
    let mut store = setup_store();

    store.transfer_ownership(acc.bob).unwrap();

    assert_eq!(store.owner(), acc.bob);
}

#[ink::test]
fn test_authorized_store_can_set_value_for() {
    let acc = accounts();
    let mut store = setup_store();
    let key = make_key("test");

    store.authorize_store(acc.bob).unwrap();
    assert!(store.is_authorized(acc.bob));

    set_caller(acc.bob);
    store
        .set_value_for(acc.charlie, key, "ipfs://QmTest".to_string())
        .unwrap();

    assert_eq!(store.get_value_for(acc.charlie, key), "ipfs://QmTest");
}

#[ink::test]
fn test_controller_locks_keys() {
    let acc = accounts();
    let mut store = setup_store();
    let key = make_key("locked");

    store.authorize_dotns_controller(acc.bob).unwrap();
    assert!(store.is_dotns_controller(acc.bob));

    set_caller(acc.bob);
    store
        .set_value_for(acc.charlie, key, "ipfs://QmLocked".to_string())
        .unwrap();

    assert!(store.is_locked(acc.charlie, key));
}

#[ink::test]
fn test_isolated_namespaces() {
    let acc = accounts();
    let mut store = setup_store();
    let key = make_key("same_key");

    set_caller(acc.alice);
    store.set_value(key, "ipfs://QmAlice".to_string()).unwrap();

    set_caller(acc.bob);
    store.set_value(key, "ipfs://QmBob".to_string()).unwrap();

    set_caller(acc.alice);
    assert_eq!(store.get_value(key), "ipfs://QmAlice");

    set_caller(acc.bob);
    assert_eq!(store.get_value(key), "ipfs://QmBob");
}
