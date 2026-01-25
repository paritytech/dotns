use crate::dotns_resolver::DotnsResolver;
use crate::resolver::BaseDotnsResolver;
use dotns_registry::DotnsRegistryRef;
use dotns_reverse_resolver::DotnsReverseResolverRef;
use dotns_store::StoreRef;
use dotns_store_factory::StoreFactoryRef;
use ink::env::hash::{HashOutput, Keccak256};
use ink::env::test;
use ink::prelude::string::String;
use ink::primitives::{H160, H256};

fn default_accounts() -> test::DefaultAccounts {
    test::default_accounts()
}

fn set_caller(caller: H160) {
    test::set_caller(caller);
}

struct TestEnv {
    resolver: DotnsResolver,
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

    let resolver = DotnsResolver::new(registry);

    TestEnv { resolver }
}

fn labelhash(label: &str) -> H256 {
    let mut output = <Keccak256 as HashOutput>::Type::default();
    ink::env::hash_bytes::<Keccak256>(label.as_bytes(), &mut output);
    H256::from(output)
}

#[ink::test]
fn test_initialization() {
    let accounts = default_accounts();
    let test_env = setup_test_env();

    assert_eq!(test_env.resolver.contract_owner(), accounts.alice);
    assert_eq!(test_env.resolver.version(), String::from("1.0.0"));
    assert_ne!(test_env.resolver.registry(), H160::zero());
}

#[ink::test]
fn test_address_of_returns_zero_for_unset_node() {
    let test_env = setup_test_env();
    let node = labelhash("unset");

    assert_eq!(test_env.resolver.address_of(node), H160::zero());
}

#[ink::test]
fn test_set_address_stores_value() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.alice);

    let root_node = H256::default();

    test_env
        .resolver
        .set_address(root_node, accounts.bob)
        .unwrap();

    assert_eq!(test_env.resolver.address_of(root_node), accounts.bob);
}
