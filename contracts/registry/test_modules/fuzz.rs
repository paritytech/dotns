use crate::dotns_registry::DotnsRegistry;
use crate::registry::{BaseDotnsRegistry, RegistryError};
use dotns_reverse_resolver::DotnsReverseResolverRef;
use dotns_store::StoreRef;
use dotns_store_factory::StoreFactoryRef;
use ink::env::hash::{HashOutput, Keccak256};
use ink::env::test;
use ink::prelude::vec::Vec;
use ink::primitives::{H160, H256};
use ink_fuzzer::{fuzz, Context};

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
    registry: DotnsRegistry,
}

fn setup_test_env() -> TestEnv {
    let accounts = default_accounts();
    set_caller(accounts.alice);

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

    let registry = DotnsRegistry::new(reverse_resolver, store_factory);

    TestEnv { registry }
}

#[fuzz(cases = 256)]
fn fuzz_set_owner_persists_owner_and_resolver(
    fuzz_context: Context,
    owner_seed: u8,
    resolver_seed: u8,
    node_bytes: Vec<u8>,
) {
    fuzz_context.apply();

    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.alice);
    test_env
        .registry
        .update_registrar_controller(accounts.alice)
        .unwrap();

    let owner = select_account(owner_seed);
    let resolver = select_account(resolver_seed);
    let node = hash_bytes(&node_bytes);

    test_env.registry.set_owner(node, owner, resolver).unwrap();

    assert_eq!(test_env.registry.owner(node), owner);
    assert_eq!(test_env.registry.resolver(node), resolver);
    assert!(test_env.registry.record_exists(node));
}

#[fuzz(cases = 256)]
fn fuzz_set_resolver_updates_resolver(
    fuzz_context: Context,
    initial_resolver_seed: u8,
    new_resolver_seed: u8,
    node_bytes: Vec<u8>,
) {
    fuzz_context.apply();

    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.alice);
    test_env
        .registry
        .update_registrar_controller(accounts.alice)
        .unwrap();

    let initial_resolver = select_account(initial_resolver_seed);
    let new_resolver = select_account(new_resolver_seed);
    let node = hash_bytes(&node_bytes);

    test_env
        .registry
        .set_owner(node, accounts.alice, initial_resolver)
        .unwrap();
    test_env.registry.set_resolver(node, new_resolver).unwrap();

    assert_eq!(test_env.registry.resolver(node), new_resolver);
}

#[fuzz(cases = 256)]
fn fuzz_transfer_ownership_updates_owner(fuzz_context: Context, new_owner_seed: u8) {
    fuzz_context.apply();

    let accounts = default_accounts();
    let mut test_env = setup_test_env();
    let new_owner = select_account(new_owner_seed);

    set_caller(accounts.alice);
    test_env.registry.transfer_ownership(new_owner).unwrap();

    assert_eq!(test_env.registry.contract_owner(), new_owner);
}

#[fuzz(cases = 256)]
fn fuzz_update_registrar_controller_persists(fuzz_context: Context, controller_seed: u8) {
    fuzz_context.apply();

    let accounts = default_accounts();
    let mut test_env = setup_test_env();
    let new_controller = select_account(controller_seed);

    set_caller(accounts.alice);
    test_env
        .registry
        .update_registrar_controller(new_controller)
        .unwrap();

    assert_eq!(test_env.registry.registrar_controller(), new_controller);
}

#[fuzz(cases = 256)]
fn fuzz_unauthorized_caller_cannot_set_resolver(
    fuzz_context: Context,
    caller_seed: u8,
    node_owner_seed: u8,
    resolver_seed: u8,
    node_bytes: Vec<u8>,
) {
    fuzz_context.apply();

    let accounts = default_accounts();
    let mut test_env = setup_test_env();
    let caller = select_account(caller_seed);
    let node_owner = select_account(node_owner_seed);
    let resolver = select_account(resolver_seed);
    let node = hash_bytes(&node_bytes);

    if caller == node_owner {
        return;
    }

    set_caller(accounts.alice);
    test_env
        .registry
        .update_registrar_controller(accounts.alice)
        .unwrap();
    test_env
        .registry
        .set_owner(node, node_owner, accounts.bob)
        .unwrap();

    set_caller(caller);
    let result = test_env.registry.set_resolver(node, resolver);

    assert_eq!(result, Err(RegistryError::NotAuthorised));
}

#[fuzz(cases = 256)]
fn fuzz_unauthorized_caller_cannot_set_owner(
    fuzz_context: Context,
    caller_seed: u8,
    owner_seed: u8,
    resolver_seed: u8,
    node_bytes: Vec<u8>,
) {
    fuzz_context.apply();

    let accounts = default_accounts();
    let mut test_env = setup_test_env();
    let caller = select_account(caller_seed);
    let owner = select_account(owner_seed);
    let resolver = select_account(resolver_seed);
    let node = hash_bytes(&node_bytes);

    set_caller(accounts.alice);
    test_env
        .registry
        .update_registrar_controller(accounts.bob)
        .unwrap();

    if caller == accounts.bob {
        return;
    }

    set_caller(caller);
    let result = test_env.registry.set_owner(node, owner, resolver);

    assert_eq!(result, Err(RegistryError::NotRegistryController));
}
