use crate::dotns_registry::DotnsRegistry;
use crate::registry::{BaseDotnsRegistry, RegistryError, SubnodeRecord};
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
fn test_transfer_ownership_reverts_when_not_owner() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    let result = test_env.registry.transfer_ownership(accounts.charlie);

    assert_eq!(result, Err(RegistryError::NotOwner));
}

#[ink::test]
fn test_update_registrar_controller_reverts_when_not_owner() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    let result = test_env
        .registry
        .update_registrar_controller(accounts.charlie);

    assert_eq!(result, Err(RegistryError::NotOwner));
}

#[ink::test]
fn test_update_registrar_controller_reverts_with_zero_address() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.alice);
    let result = test_env.registry.update_registrar_controller(H160::zero());

    assert_eq!(result, Err(RegistryError::NotAllowed));
}

#[ink::test]
fn test_set_owner_reverts_when_not_registrar_controller() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.alice);
    let node = labelhash("testnode");
    let result = test_env
        .registry
        .set_owner(node, accounts.bob, accounts.charlie);

    assert_eq!(result, Err(RegistryError::NotRegistryController));
}

#[ink::test]
fn test_set_owner_reverts_with_zero_owner_address() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.alice);
    test_env
        .registry
        .update_registrar_controller(accounts.alice)
        .unwrap();

    let node = labelhash("testnode");
    let result = test_env
        .registry
        .set_owner(node, H160::zero(), accounts.charlie);

    assert_eq!(result, Err(RegistryError::NotAllowed));
}

#[ink::test]
fn test_set_owner_reverts_when_node_already_owned() {
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

    let result = test_env
        .registry
        .set_owner(node, accounts.django, accounts.eve);

    assert_eq!(result, Err(RegistryError::NodeAlreadyOwned { node }));
}

#[ink::test]
fn test_set_subnode_owner_reverts_when_not_parent_owner() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);

    let root_node = H256::default();
    let record = SubnodeRecord {
        parent_node: root_node,
        sub_label: String::from("alice"),
        parent_label: String::from("dot"),
        owner: accounts.charlie,
    };

    let result = test_env.registry.set_subnode_owner(record);

    assert_eq!(result, Err(RegistryError::NotAuthorised));
}

#[ink::test]
fn test_set_subnode_owner_reverts_with_zero_owner_address() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.alice);

    let root_node = H256::default();
    let record = SubnodeRecord {
        parent_node: root_node,
        sub_label: String::from("alice"),
        parent_label: String::from("dot"),
        owner: H160::zero(),
    };

    let result = test_env.registry.set_subnode_owner(record);

    assert_eq!(result, Err(RegistryError::NotAllowed));
}

#[ink::test]
fn test_set_subnode_owner_reverts_when_subnode_exists() {
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

    let duplicate_record = SubnodeRecord {
        parent_node: root_node,
        sub_label: String::from("alice"),
        parent_label: String::from("dot"),
        owner: accounts.charlie,
    };

    let result = test_env.registry.set_subnode_owner(duplicate_record);

    assert_eq!(result, Err(RegistryError::NodeAlreadyExists { subnode }));
}

#[ink::test]
fn test_set_resolver_reverts_when_not_node_owner() {
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

    set_caller(accounts.django);
    let result = test_env.registry.set_resolver(node, accounts.eve);

    assert_eq!(result, Err(RegistryError::NotAuthorised));
}
