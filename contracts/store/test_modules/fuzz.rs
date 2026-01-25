use crate::dotns_store::Store;
use crate::store_base::StoreBase;
use ink::prelude::string::{String, ToString};
use ink::primitives::H160;
use ink_fuzzer::{fuzz, Context};

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

fn make_key(bytes: &[u8]) -> [u8; 32] {
    let mut key = [0u8; 32];
    if bytes.is_empty() {
        key[0] = 1;
        return key;
    }
    let len = bytes.len().min(32);
    key[..len].copy_from_slice(&bytes[..len]);
    key
}

fn ascii_string(bytes: &[u8], max_len: usize) -> String {
    if bytes.is_empty() {
        return String::from("a");
    }
    let len = 1 + (bytes.len() % max_len);
    let mut out = Vec::with_capacity(len);
    for i in 0..len {
        out.push(b'a' + (bytes[i % bytes.len()] % 26));
    }
    String::from_utf8(out).unwrap_or_else(|_| String::from("a"))
}

#[fuzz(cases = 256)]
fn fuzz_set_get_roundtrip(ctx: Context, key_bytes: Vec<u8>, value_bytes: Vec<u8>) {
    ctx.apply();

    let mut store = setup_store();
    let key = make_key(&key_bytes);
    let value = ascii_string(&value_bytes, 100);

    store.set_value(key, value.clone()).unwrap();
    let retrieved = store.get_value(key);

    assert_eq!(retrieved, value);
}

#[fuzz(cases = 256)]
fn fuzz_delete_removes_value(ctx: Context, key_bytes: Vec<u8>) {
    ctx.apply();

    let mut store = setup_store();
    let key = make_key(&key_bytes);

    store.set_value(key, "ipfs://QmTest".to_string()).unwrap();
    assert!(store.has_value(key));

    store.delete_value(key).unwrap();
    assert!(!store.has_value(key));
    assert_eq!(store.get_value(key), String::new());
}

#[fuzz(cases = 256)]
fn fuzz_isolated_namespaces(
    ctx: Context,
    key_bytes: Vec<u8>,
    value1_bytes: Vec<u8>,
    value2_bytes: Vec<u8>,
) {
    ctx.apply();

    let acc = accounts();
    let mut store = setup_store();
    let key = make_key(&key_bytes);
    let value1 = ascii_string(&value1_bytes, 50);
    let value2 = ascii_string(&value2_bytes, 50);

    set_caller(acc.alice);
    store.set_value(key, value1.clone()).unwrap();

    set_caller(acc.bob);
    store.set_value(key, value2.clone()).unwrap();

    set_caller(acc.alice);
    assert_eq!(store.get_value(key), value1);

    set_caller(acc.bob);
    assert_eq!(store.get_value(key), value2);
}

#[fuzz(cases = 128)]
fn fuzz_transfer_ownership(ctx: Context, key_bytes: Vec<u8>) {
    ctx.apply();

    let acc = accounts();
    let mut store = setup_store();

    store.transfer_ownership(acc.bob).unwrap();
    assert_eq!(store.owner(), acc.bob);

    set_caller(acc.alice);
    let key = make_key(&key_bytes);
    store
        .set_value(key, "ipfs://QmAlice".to_string())
        .expect("alice can still set her own values");
}

#[fuzz(cases = 128)]
fn fuzz_authorized_set_value_for(ctx: Context, key_bytes: Vec<u8>, value_bytes: Vec<u8>) {
    ctx.apply();

    let acc = accounts();
    let mut store = setup_store();
    let key = make_key(&key_bytes);
    let value = ascii_string(&value_bytes, 100);

    store.authorize_store(acc.bob).unwrap();

    set_caller(acc.bob);
    store
        .set_value_for(acc.charlie, key, value.clone())
        .unwrap();

    assert_eq!(store.get_value_for(acc.charlie, key), value);
}

#[fuzz(cases = 128)]
fn fuzz_locked_keys_immutable(ctx: Context, key_bytes: Vec<u8>) {
    ctx.apply();

    let acc = accounts();
    let mut store = setup_store();
    let key = make_key(&key_bytes);

    store.authorize_dotns_controller(acc.bob).unwrap();

    set_caller(acc.bob);
    store
        .set_value_for(acc.charlie, key, "ipfs://QmLocked".to_string())
        .unwrap();

    assert!(store.is_locked(acc.charlie, key));

    set_caller(acc.charlie);
    let overwrite = store.set_value(key, "ipfs://QmNew".to_string());
    assert!(overwrite.is_err());

    let delete = store.delete_value(key);
    assert!(delete.is_err());
}
