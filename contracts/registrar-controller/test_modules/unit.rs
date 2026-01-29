use crate::registrar_controller::{
    BaseDotnsRegistrarController, RegistrarControllerError, Registration,
};
use crate::DotnsRegistrarControllerRef;

use dotns_pop_rules::base_pop_rules::BaseDotnsPopRules;
use dotns_pop_rules::DotnsPopRulesRef;
use dotns_registrar::registrar::BaseDotnsRegistrar;
use dotns_registrar::DotnsRegistrarRef;
use dotns_registry::registry::BaseDotnsRegistry;
use dotns_registry::DotnsRegistryRef;
use dotns_reverse_resolver::reverse_resolver::BaseDotnsReverseResolver;
use dotns_reverse_resolver::DotnsReverseResolverRef;
use dotns_store::StoreRef;
use dotns_store_factory::StoreFactoryRef;
use ink::env::hash::{HashOutput, Keccak256};
use ink::env::test;
use ink::prelude::string::String;
use ink::prelude::vec::Vec;
use ink::primitives::{H160, H256};
use ink::ToAddr;

fn default_accounts() -> test::DefaultAccounts {
    test::default_accounts()
}

fn set_caller(addr: H160) {
    test::set_caller(addr);
}

fn set_block_timestamp(ts: u64) {
    test::set_block_timestamp::<ink::env::DefaultEnvironment>(ts);
}

fn hash_bytes(data: &[u8]) -> H256 {
    let mut out = <Keccak256 as HashOutput>::Type::default();
    ink::env::hash_bytes::<Keccak256>(data, &mut out);
    H256::from(out)
}

struct TestEnv {
    controller: DotnsRegistrarControllerRef,
}

fn setup_test_env() -> TestEnv {
    let accounts = default_accounts();
    set_caller(accounts.alice);

    let registrar_code_hash =
        test::upload_code::<ink::env::DefaultEnvironment, DotnsRegistrarRef>();
    let registry_code_hash = test::upload_code::<ink::env::DefaultEnvironment, DotnsRegistryRef>();
    let reverse_code_hash =
        test::upload_code::<ink::env::DefaultEnvironment, DotnsReverseResolverRef>();
    let pop_rules_code_hash = test::upload_code::<ink::env::DefaultEnvironment, DotnsPopRulesRef>();
    let store_factory_code_hash =
        test::upload_code::<ink::env::DefaultEnvironment, StoreFactoryRef>();
    let store_code_hash = test::upload_code::<ink::env::DefaultEnvironment, StoreRef>();
    let controller_code_hash =
        test::upload_code::<ink::env::DefaultEnvironment, DotnsRegistrarControllerRef>();

    let mut registrar = DotnsRegistrarRef::new(String::from("DotNS"), String::from("DNS"))
        .code_hash(registrar_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([0u8; 32]))
        .instantiate();

    let mut reverse = DotnsReverseResolverRef::new()
        .code_hash(reverse_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([1u8; 32]))
        .instantiate();

    let store_factory = StoreFactoryRef::new(store_code_hash)
        .code_hash(store_factory_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([2u8; 32]))
        .instantiate();

    let mut registry = DotnsRegistryRef::new(reverse.clone(), store_factory.clone())
        .code_hash(registry_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([3u8; 32]))
        .instantiate();

    let mut pop_rules = DotnsPopRulesRef::new(1_000_000u128)
        .code_hash(pop_rules_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([4u8; 32]))
        .instantiate();

    let controller = DotnsRegistrarControllerRef::new(
        registrar.clone(),
        registry.clone(),
        reverse.clone(),
        pop_rules.clone(),
        store_factory.clone(),
        60,
        3600,
    )
    .code_hash(controller_code_hash)
    .endowment(0.into())
    .salt_bytes(Some([5u8; 32]))
    .instantiate()
    .unwrap();

    let controller_addr = controller.to_addr();

    reverse
        .update_registrar_controller(controller_addr)
        .unwrap();
    pop_rules.update_registry(controller_addr).unwrap();
    registrar.add_controller(controller_addr).unwrap();
    registry
        .update_registrar_controller(controller_addr)
        .unwrap();

    TestEnv { controller }
}

#[ink::test]
fn test_available_returns_true_for_valid_unregistered_label() {
    let test_env = setup_test_env();

    let result = test_env.controller.available(String::from("validname01"));

    assert!(result.unwrap());
}

#[ink::test]
fn test_available_fails_for_short_label() {
    let test_env = setup_test_env();

    let result = test_env.controller.available(String::from("ab"));

    assert!(matches!(
        result,
        Err(RegistrarControllerError::NameNotAvailable { .. })
    ));
}

#[ink::test]
fn test_available_fails_for_two_char_label() {
    let test_env = setup_test_env();

    let result = test_env.controller.available(String::from("xy"));

    assert!(matches!(
        result,
        Err(RegistrarControllerError::NameNotAvailable { .. })
    ));
}

#[ink::test]
fn test_available_succeeds_for_three_char_label() {
    let test_env = setup_test_env();

    let result = test_env.controller.available(String::from("abc"));

    assert!(result.unwrap());
}

#[ink::test]
fn test_make_commitment_is_deterministic() {
    let accounts = default_accounts();
    let test_env = setup_test_env();

    let secret = hash_bytes(b"secret");
    let registration = Registration {
        label: String::from("testlabel01"),
        owner: accounts.bob,
        secret,
        reserved: false,
    };

    let first = test_env.controller.make_commitment(registration.clone());
    let second = test_env.controller.make_commitment(registration);

    assert_eq!(first, second);
}

#[ink::test]
fn test_make_commitment_matches_manual_hash() {
    let accounts = default_accounts();
    let test_env = setup_test_env();

    let label = String::from("testlabel01");
    let secret = hash_bytes(b"secret");
    let reserved = true;

    let registration = Registration {
        label: label.clone(),
        owner: accounts.bob,
        secret,
        reserved,
    };

    let commitment = test_env.controller.make_commitment(registration);

    let mut expected_data = Vec::new();
    expected_data.extend_from_slice(label.as_bytes());
    expected_data.extend_from_slice(accounts.bob.as_bytes());
    expected_data.extend_from_slice(secret.as_bytes());
    expected_data.push(1u8);

    let expected = hash_bytes(&expected_data);

    assert_eq!(commitment, expected);
}

#[ink::test]
fn test_make_commitment_different_for_different_secrets() {
    let accounts = default_accounts();
    let test_env = setup_test_env();

    let first = Registration {
        label: String::from("testlabel01"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret1"),
        reserved: false,
    };

    let second = Registration {
        label: String::from("testlabel01"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret2"),
        reserved: false,
    };

    assert_ne!(
        test_env.controller.make_commitment(first),
        test_env.controller.make_commitment(second)
    );
}

#[ink::test]
fn test_make_commitment_different_for_different_owners() {
    let accounts = default_accounts();
    let test_env = setup_test_env();

    let secret = hash_bytes(b"secret");

    let first = Registration {
        label: String::from("testlabel01"),
        owner: accounts.bob,
        secret,
        reserved: false,
    };

    let second = Registration {
        label: String::from("testlabel01"),
        owner: accounts.charlie,
        secret,
        reserved: false,
    };

    assert_ne!(
        test_env.controller.make_commitment(first),
        test_env.controller.make_commitment(second)
    );
}

#[ink::test]
fn test_make_commitment_different_for_different_labels() {
    let accounts = default_accounts();
    let test_env = setup_test_env();

    let secret = hash_bytes(b"secret");

    let first = Registration {
        label: String::from("labelone01"),
        owner: accounts.bob,
        secret,
        reserved: false,
    };

    let second = Registration {
        label: String::from("labeltwo01"),
        owner: accounts.bob,
        secret,
        reserved: false,
    };

    assert_ne!(
        test_env.controller.make_commitment(first),
        test_env.controller.make_commitment(second)
    );
}

#[ink::test]
fn test_make_commitment_different_for_reserved_flag() {
    let accounts = default_accounts();
    let test_env = setup_test_env();

    let secret = hash_bytes(b"secret");

    let reserved = Registration {
        label: String::from("testlabel01"),
        owner: accounts.bob,
        secret,
        reserved: true,
    };

    let unreserved = Registration {
        label: String::from("testlabel01"),
        owner: accounts.bob,
        secret,
        reserved: false,
    };

    assert_ne!(
        test_env.controller.make_commitment(reserved),
        test_env.controller.make_commitment(unreserved)
    );
}

#[ink::test]
fn test_commit_stores_timestamp() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    set_block_timestamp(5000);

    let registration = Registration {
        label: String::from("testlabel01"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: false,
    };

    let commitment = test_env.controller.make_commitment(registration);
    test_env.controller.commit(commitment).unwrap();

    assert_eq!(test_env.controller.commitment_timestamp(commitment), 5000);
}

#[ink::test]
fn test_commit_fails_for_unexpired_commitment() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    set_block_timestamp(1000);

    let registration = Registration {
        label: String::from("testlabel01"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: false,
    };

    let commitment = test_env.controller.make_commitment(registration);
    test_env.controller.commit(commitment).unwrap();

    set_block_timestamp(1000 + 1800);

    let result = test_env.controller.commit(commitment);

    assert!(matches!(
        result,
        Err(RegistrarControllerError::UnexpiredCommitmentExists { .. })
    ));
}

#[ink::test]
fn test_commit_succeeds_after_expiry() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    set_block_timestamp(1000);

    let registration = Registration {
        label: String::from("testlabel01"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: false,
    };

    let commitment = test_env.controller.make_commitment(registration);
    test_env.controller.commit(commitment).unwrap();

    let max_age = test_env.controller.max_commitment_age();
    set_block_timestamp(1000 + max_age + 1);

    test_env.controller.commit(commitment).unwrap();

    assert_eq!(
        test_env.controller.commitment_timestamp(commitment),
        1000 + max_age + 1
    );
}

#[ink::test]
fn test_commitment_timestamp_returns_zero_for_unknown() {
    let test_env = setup_test_env();

    let unknown = hash_bytes(b"unknown_commitment");

    assert_eq!(test_env.controller.commitment_timestamp(unknown), 0);
}

#[ink::test]
fn test_owner_is_deployer() {
    let accounts = default_accounts();
    let test_env = setup_test_env();

    assert_eq!(test_env.controller.owner(), accounts.alice);
}

#[ink::test]
fn test_transfer_ownership_succeeds() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.alice);
    test_env
        .controller
        .transfer_ownership(accounts.bob)
        .unwrap();

    assert_eq!(test_env.controller.owner(), accounts.bob);
}

#[ink::test]
fn test_transfer_ownership_fails_for_non_owner() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    let result = test_env.controller.transfer_ownership(accounts.charlie);

    assert!(matches!(result, Err(RegistrarControllerError::NotOwner)));
    assert_eq!(test_env.controller.owner(), accounts.alice);
}

#[ink::test]
fn test_new_owner_can_transfer() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.alice);
    test_env
        .controller
        .transfer_ownership(accounts.bob)
        .unwrap();

    set_caller(accounts.bob);
    test_env
        .controller
        .transfer_ownership(accounts.charlie)
        .unwrap();

    assert_eq!(test_env.controller.owner(), accounts.charlie);
}

#[ink::test]
fn test_min_commitment_age() {
    let test_env = setup_test_env();

    assert_eq!(test_env.controller.min_commitment_age(), 60);
}

#[ink::test]
fn test_max_commitment_age() {
    let test_env = setup_test_env();

    assert_eq!(test_env.controller.max_commitment_age(), 3600);
}

#[ink::test]
fn test_version() {
    let test_env = setup_test_env();

    assert_eq!(test_env.controller.version(), String::from("1.1.0"));
}

#[ink::test]
fn test_contract_references_are_non_zero() {
    let test_env = setup_test_env();

    assert_ne!(test_env.controller.dotns_registrar(), H160::zero());
    assert_ne!(test_env.controller.dotns_registry(), H160::zero());
    assert_ne!(test_env.controller.reverse_resolver(), H160::zero());
    assert_ne!(test_env.controller.pop_rules(), H160::zero());
    assert_ne!(test_env.controller.store_factory(), H160::zero());
}
