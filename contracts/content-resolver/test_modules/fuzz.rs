use crate::content_resolver::{ContentResolver, ContentResolverError};
use crate::dotns_content_resolver::*;
use dotns_registry::DotnsRegistryRef;
use dotns_registry::registry::BaseDotnsRegistry;
use dotns_reverse_resolver::DotnsReverseResolverRef;
use dotns_store::StoreRef;
use dotns_store_factory::StoreFactoryRef;
use ink::env::test;
use ink::prelude::string::String;
use ink::prelude::vec::Vec;
use ink::primitives::{H160, H256, U256};
use ink_fuzzer::{Context, fuzz};

fn accounts() -> test::DefaultAccounts {
    test::default_accounts()
}

fn set_caller(caller: H160) {
    test::set_caller(caller);
}

fn select_account(seed: u8) -> H160 {
    let acc = accounts();
    match seed % 5 {
        0 => acc.alice,
        1 => acc.bob,
        2 => acc.charlie,
        3 => acc.django,
        _ => acc.eve,
    }
}

fn node_from_bytes(bytes: &[u8]) -> H256 {
    use ink::env::hash::{HashOutput, Keccak256};
    let mut output = <Keccak256 as HashOutput>::Type::default();
    ink::env::hash_bytes::<Keccak256>(bytes, &mut output);
    H256::from(output)
}

fn setup_registry() -> DotnsRegistryRef {
    let acc = accounts();

    let store_factory_code_hash =
        test::upload_code::<ink::env::DefaultEnvironment, StoreFactoryRef>();
    let store_code_hash = test::upload_code::<ink::env::DefaultEnvironment, StoreRef>();
    let store_factory = StoreFactoryRef::new(store_code_hash)
        .code_hash(store_factory_code_hash)
        .endowment(U256::from(0))
        .salt_bytes(Some([0x01; 32]))
        .instantiate();

    let reverse_resolver_code_hash =
        test::upload_code::<ink::env::DefaultEnvironment, DotnsReverseResolverRef>();
    let reverse_resolver = DotnsReverseResolverRef::new()
        .code_hash(reverse_resolver_code_hash)
        .endowment(U256::from(0))
        .salt_bytes(Some([0x02; 32]))
        .instantiate();

    let registry_code_hash = test::upload_code::<ink::env::DefaultEnvironment, DotnsRegistryRef>();
    let mut registry = DotnsRegistryRef::new(reverse_resolver, store_factory)
        .code_hash(registry_code_hash)
        .endowment(U256::from(0))
        .salt_bytes(Some([0x03; 32]))
        .instantiate();

    registry.update_registrar_controller(acc.alice).unwrap();

    registry
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
fn fuzz_only_owner_or_operator_can_set_contenthash(
    ctx: Context,
    owner_seed: u8,
    caller_seed: u8,
    node_bytes: Vec<u8>,
    hash: Vec<u8>,
) {
    ctx.apply();

    let acc = accounts();
    let owner = select_account(owner_seed);
    let caller = select_account(caller_seed);
    let node = node_from_bytes(&node_bytes);

    set_caller(acc.alice);
    let mut registry = setup_registry();
    registry.set_owner(node, owner, H160::default()).unwrap();

    let mut resolver = DotnsContentResolver::new(registry);

    set_caller(caller);
    let result = resolver.set_contenthash(node, hash.clone());

    if caller == owner {
        assert!(result.is_ok());
        assert_eq!(resolver.contenthash(node), hash);
    } else {
        assert_eq!(
            result,
            Err(ContentResolverError::NotAuthorised { node, caller })
        );
    }
}

#[fuzz(cases = 256)]
fn fuzz_only_owner_or_operator_can_set_text(
    ctx: Context,
    owner_seed: u8,
    caller_seed: u8,
    node_bytes: Vec<u8>,
    key_bytes: Vec<u8>,
    value_bytes: Vec<u8>,
) {
    ctx.apply();

    let acc = accounts();
    let owner = select_account(owner_seed);
    let caller = select_account(caller_seed);
    let node = node_from_bytes(&node_bytes);
    let key = ascii_string(&key_bytes, 32);
    let value = ascii_string(&value_bytes, 100);

    set_caller(acc.alice);
    let mut registry = setup_registry();
    registry.set_owner(node, owner, H160::default()).unwrap();

    let mut resolver = DotnsContentResolver::new(registry);

    set_caller(caller);
    let result = resolver.set_text(node, key.clone(), value.clone());

    if caller == owner {
        assert!(result.is_ok());
        assert_eq!(resolver.text(node, key), value);
    } else {
        assert_eq!(
            result,
            Err(ContentResolverError::NotAuthorised { node, caller })
        );
    }
}

#[fuzz(cases = 256)]
fn fuzz_operator_approval_enables_access(
    ctx: Context,
    owner_seed: u8,
    operator_seed: u8,
    node_bytes: Vec<u8>,
    hash: Vec<u8>,
) {
    ctx.apply();

    let acc = accounts();
    let owner = select_account(owner_seed);
    let operator = select_account(operator_seed);
    let node = node_from_bytes(&node_bytes);

    set_caller(acc.alice);
    let mut registry = setup_registry();
    registry.set_owner(node, owner, H160::default()).unwrap();

    let mut resolver = DotnsContentResolver::new(registry);

    set_caller(owner);
    resolver.set_approval_for_all(operator, true);

    assert!(resolver.is_approved_for_all(owner, operator));

    set_caller(operator);
    let result = resolver.set_contenthash(node, hash.clone());

    assert!(result.is_ok());
    assert_eq!(resolver.contenthash(node), hash);
}

#[fuzz(cases = 256)]
fn fuzz_contenthash_roundtrip(ctx: Context, node_bytes: Vec<u8>, hash: Vec<u8>) {
    ctx.apply();

    let acc = accounts();
    let node = node_from_bytes(&node_bytes);

    set_caller(acc.alice);
    let mut registry = setup_registry();
    registry
        .set_owner(node, acc.alice, H160::default())
        .unwrap();

    let mut resolver = DotnsContentResolver::new(registry);

    resolver.set_contenthash(node, hash.clone()).unwrap();

    assert_eq!(resolver.contenthash(node), hash);
}

#[fuzz(cases = 256)]
fn fuzz_text_roundtrip(
    ctx: Context,
    node_bytes: Vec<u8>,
    key_bytes: Vec<u8>,
    value_bytes: Vec<u8>,
) {
    ctx.apply();

    let acc = accounts();
    let node = node_from_bytes(&node_bytes);
    let key = ascii_string(&key_bytes, 32);
    let value = ascii_string(&value_bytes, 100);

    set_caller(acc.alice);
    let mut registry = setup_registry();
    registry
        .set_owner(node, acc.alice, H160::default())
        .unwrap();

    let mut resolver = DotnsContentResolver::new(registry);

    resolver.set_text(node, key.clone(), value.clone()).unwrap();

    assert_eq!(resolver.text(node, key), value);
}

#[fuzz(cases = 256)]
fn fuzz_transfer_ownership_only_owner(ctx: Context, caller_seed: u8, new_owner_seed: u8) {
    ctx.apply();

    let acc = accounts();
    let caller = select_account(caller_seed);
    let new_owner = select_account(new_owner_seed);

    set_caller(acc.alice);
    let registry = setup_registry();
    let mut resolver = DotnsContentResolver::new(registry);

    set_caller(caller);
    let result = resolver.transfer_ownership(new_owner);

    if caller == acc.alice {
        assert!(result.is_ok());
        assert_eq!(resolver.owner(), new_owner);
    } else {
        assert_eq!(result, Err(ContentResolverError::NotOwner));
        assert_eq!(resolver.owner(), acc.alice);
    }
}
