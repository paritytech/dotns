use crate::dotns_registry::DotnsRegistry;
use crate::registry::{BaseDotnsRegistry, SubnodeRecord};
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

fn labelhash(label: &str) -> H256 {
    let mut output = <Keccak256 as HashOutput>::Type::default();
    ink::env::hash_bytes::<Keccak256>(label.as_bytes(), &mut output);
    H256::from(output)
}

#[ink::test]
fn test_initialization() {
    let accounts = default_accounts();
    let test_env = setup_test_env();
    let root_node = H256::default();

    assert_eq!(test_env.registry.contract_owner(), accounts.alice);
    assert_eq!(test_env.registry.version(), String::from("1.2.0"));
    assert_eq!(test_env.registry.registrar_controller(), H160::zero());
    assert_ne!(test_env.registry.reverse_resolver(), H160::zero());
    assert_ne!(test_env.registry.store_factory(), H160::zero());
    assert!(test_env.registry.record_exists(root_node));
    assert_eq!(test_env.registry.owner(root_node), accounts.alice);
}

#[ink::test]
fn test_non_existent_node_returns_defaults() {
    let test_env = setup_test_env();
    let unknown_node = labelhash("unknown");

    assert!(!test_env.registry.record_exists(unknown_node));
    assert_eq!(test_env.registry.owner(unknown_node), H160::zero());
    assert_eq!(test_env.registry.resolver(unknown_node), H160::zero());
}

#[ink::test]
fn test_transfer_ownership() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.alice);
    test_env.registry.transfer_ownership(accounts.bob).unwrap();

    assert_eq!(test_env.registry.contract_owner(), accounts.bob);
}

#[ink::test]
fn test_update_registrar_controller() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.alice);
    test_env
        .registry
        .update_registrar_controller(accounts.bob)
        .unwrap();

    assert_eq!(test_env.registry.registrar_controller(), accounts.bob);
}

#[ink::test]
fn test_set_owner_creates_node() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.alice);
    test_env
        .registry
        .update_registrar_controller(accounts.alice)
        .unwrap();

    let node = labelhash("testnode");

    test_env
        .registry
        .set_owner(node, accounts.bob, accounts.charlie)
        .unwrap();

    assert!(test_env.registry.record_exists(node));
    assert_eq!(test_env.registry.owner(node), accounts.bob);
    assert_eq!(test_env.registry.resolver(node), accounts.charlie);
}

#[ink::test]
fn test_set_resolver() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.alice);
    test_env
        .registry
        .update_registrar_controller(accounts.alice)
        .unwrap();

    let node = labelhash("testnode");
    test_env
        .registry
        .set_owner(node, accounts.alice, accounts.bob)
        .unwrap();

    test_env
        .registry
        .set_resolver(node, accounts.charlie)
        .unwrap();

    assert_eq!(test_env.registry.resolver(node), accounts.charlie);
}

#[ink::test]
fn test_set_subnode_owner() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.alice);

    let root_node = H256::default();
    let record = SubnodeRecord {
        parent_node: root_node,
        sub_label: String::from("alice"),
        parent_label: String::from("dot"),
        owner: accounts.bob,
    };

    let subnode = test_env.registry.set_subnode_owner(record).unwrap();

    assert!(test_env.registry.record_exists(subnode));
    assert_eq!(test_env.registry.owner(subnode), accounts.bob);
    assert_eq!(
        test_env.registry.resolver(subnode),
        test_env.registry.reverse_resolver()
    );
}
