use crate::dotns_resolver::DotnsResolver;
use crate::resolver::{BaseDotnsResolver, ResolverError};
use dotns_registry::DotnsRegistryRef;
use dotns_registry::registry::BaseDotnsRegistry;
use dotns_reverse_resolver::DotnsReverseResolverRef;
use dotns_store::StoreRef;
use dotns_store_factory::StoreFactoryRef;
use ink::env::hash::{HashOutput, Keccak256};
use ink::env::test;
use ink::prelude::vec::Vec;
use ink::primitives::{H160, H256};
use ink_fuzzer::{Context, fuzz};

fn default_accounts() -> test::DefaultAccounts {
    test::default_accounts()
}

fn set_caller(caller: H160) {
    test::set_caller(caller);
}

fn hash_bytes(data: &[u8]) -> H256 {
    let mut output = <Keccak256 as HashOutput>::Type::default();
    ink::env::hash_bytes::<Keccak256>(data, &mut output);
    H256::from(output)
}

fn select_account(seed: u8) -> H160 {
    let accounts = default_accounts();
    match seed % 5 {
        0 => accounts.alice,
        1 => accounts.bob,
        2 => accounts.charlie,
        3 => accounts.django,
        _ => accounts.eve,
    }
}

struct TestEnv {
    resolver: DotnsResolver,
    registry: DotnsRegistryRef,
}

fn setup_test_env() -> TestEnv {
    let accounts = default_accounts();
    set_caller(accounts.alice);

    let registry_code_hash = test::upload_code::<ink::env::DefaultEnvironment, DotnsRegistryRef>();
    let reverse_resolver_code_hash =
        test::upload_code::<ink::env::DefaultEnvironment, DotnsReverseResolverRef>();
    let store_factory_code_hash =
        test::upload_code::<ink::env::DefaultEnvironment, StoreFactoryRef>();
    let store_code_hash = test::upload_code::<ink::env::DefaultEnvironment, StoreRef>();

    let reverse_resolver = DotnsReverseResolverRef::new()
        .code_hash(reverse_resolver_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([0u8; 32]))
        .instantiate();

    let store_factory = StoreFactoryRef::new(store_code_hash)
        .code_hash(store_factory_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([1u8; 32]))
        .instantiate();

    let registry = DotnsRegistryRef::new(reverse_resolver, store_factory)
        .code_hash(registry_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([2u8; 32]))
        .instantiate();

    let resolver = DotnsResolver::new(registry.clone());

    TestEnv { resolver, registry }
}

#[fuzz(cases = 256)]
fn fuzz_owner_can_set_address(
    fuzz_context: Context,
    owner_seed: u8,
    value_seed: u8,
    node_bytes: Vec<u8>,
) {
    fuzz_context.apply();

    let accounts = default_accounts();
    let mut test_env = setup_test_env();
    let owner = select_account(owner_seed);
    let value = select_account(value_seed);
    let node = hash_bytes(&node_bytes);

    set_caller(accounts.alice);
    test_env
        .registry
        .update_registrar_controller(accounts.alice)
        .unwrap();
    test_env
        .registry
        .set_owner(node, owner, accounts.alice)
        .unwrap();

    set_caller(owner);
    test_env.resolver.set_address(node, value).unwrap();

    assert_eq!(test_env.resolver.address_of(node), value);
}

#[fuzz(cases = 256)]
fn fuzz_unauthorized_caller_cannot_set_address(
    fuzz_context: Context,
    caller_seed: u8,
    value_seed: u8,
    node_bytes: Vec<u8>,
) {
    fuzz_context.apply();

    let accounts = default_accounts();
    let mut test_env = setup_test_env();
    let caller = select_account(caller_seed);
    let value = select_account(value_seed);
    let node = hash_bytes(&node_bytes);

    set_caller(accounts.alice);
    test_env
        .registry
        .update_registrar_controller(accounts.alice)
        .unwrap();
    test_env
        .registry
        .set_owner(node, accounts.bob, accounts.alice)
        .unwrap();

    if caller == accounts.bob {
        return;
    }

    set_caller(caller);

    let result = test_env.resolver.set_address(node, value);

    assert_eq!(result, Err(ResolverError::NotAuthorised { node, caller }));
}

#[fuzz(cases = 256)]
fn fuzz_address_of_returns_zero_for_unset_nodes(fuzz_context: Context, node_bytes: Vec<u8>) {
    fuzz_context.apply();

    let test_env = setup_test_env();
    let node = hash_bytes(&node_bytes);

    assert_eq!(test_env.resolver.address_of(node), H160::zero());
}
