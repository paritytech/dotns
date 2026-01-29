use crate::dotns_registrar_controller::DotnsRegistrarController;
use crate::registrar_controller::{
    BaseDotnsRegistrarController, RegistrarControllerError, Registration,
};
use dotns_pop_rules::base_pop_rules::{BaseDotnsPopRules, PopStatus};
use dotns_pop_rules::DotnsPopRulesRef;
use dotns_registrar::DotnsRegistrarRef;
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

fn set_block_timestamp(timestamp: u64) {
    test::set_block_timestamp::<ink::env::DefaultEnvironment>(timestamp);
}

fn set_value_transferred(value: u128) {
    test::set_value_transferred(value.into());
}

fn hash_bytes(data: &[u8]) -> H256 {
    let mut output = <Keccak256 as HashOutput>::Type::default();
    ink::env::hash_bytes::<Keccak256>(data, &mut output);
    H256::from(output)
}

struct TestEnv {
    controller: DotnsRegistrarController,
    pop_rules: DotnsPopRulesRef,
}

fn setup_test_env() -> TestEnv {
    let accounts = default_accounts();
    set_caller(accounts.alice);

    let registrar_code_hash =
        test::upload_code::<ink::env::DefaultEnvironment, DotnsRegistrarRef>();
    let registry_code_hash = test::upload_code::<ink::env::DefaultEnvironment, DotnsRegistryRef>();
    let reverse_resolver_code_hash =
        test::upload_code::<ink::env::DefaultEnvironment, DotnsReverseResolverRef>();
    let pop_rules_code_hash = test::upload_code::<ink::env::DefaultEnvironment, DotnsPopRulesRef>();
    let store_factory_code_hash =
        test::upload_code::<ink::env::DefaultEnvironment, StoreFactoryRef>();
    let store_code_hash = test::upload_code::<ink::env::DefaultEnvironment, StoreRef>();

    let registrar = DotnsRegistrarRef::new(String::from("DotNS"), String::from("DNS"))
        .code_hash(registrar_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([0u8; 32]))
        .instantiate();

    let reverse_resolver = DotnsReverseResolverRef::new()
        .code_hash(reverse_resolver_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([2u8; 32]))
        .instantiate();

    let store_factory = StoreFactoryRef::new(store_code_hash)
        .code_hash(store_factory_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([4u8; 32]))
        .instantiate();

    let registry = DotnsRegistryRef::new(reverse_resolver.clone(), store_factory.clone())
        .code_hash(registry_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([1u8; 32]))
        .instantiate();

    let pop_rules = DotnsPopRulesRef::new(1_000_000u128)
        .code_hash(pop_rules_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([3u8; 32]))
        .instantiate();

    let controller = DotnsRegistrarController::new(
        registrar,
        registry,
        reverse_resolver,
        pop_rules.clone(),
        store_factory,
        60,
        3600,
    )
    .unwrap();

    TestEnv {
        controller,
        pop_rules,
    }
}

fn commit_and_advance(
    test_env: &mut TestEnv,
    registration: &Registration,
    caller: H160,
    commit_timestamp: u64,
) {
    set_block_timestamp(commit_timestamp);
    set_caller(caller);
    let commitment = test_env.controller.make_commitment(registration.clone());
    test_env.controller.commit(commitment).unwrap();
    set_block_timestamp(commit_timestamp + 61);
}

#[ink::test]
fn test_available_reverts_for_single_character_label() {
    let test_env = setup_test_env();

    let result = test_env.controller.available(String::from("a"));

    assert!(matches!(
        result,
        Err(RegistrarControllerError::NameNotAvailable { .. })
    ));
}

#[ink::test]
fn test_available_reverts_for_two_character_label() {
    let test_env = setup_test_env();

    let result = test_env.controller.available(String::from("ab"));

    assert!(matches!(
        result,
        Err(RegistrarControllerError::NameNotAvailable { .. })
    ));
}

#[ink::test]
fn test_available_reverts_for_empty_label() {
    let test_env = setup_test_env();

    let result = test_env.controller.available(String::from(""));

    assert!(matches!(
        result,
        Err(RegistrarControllerError::NameNotAvailable { .. })
    ));
}

#[ink::test]
fn test_commit_reverts_for_unexpired_commitment() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    set_block_timestamp(1000);

    let registration = Registration {
        label: String::from("longername01"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: true,
    };

    let commitment = test_env.controller.make_commitment(registration);
    test_env.controller.commit(commitment).unwrap();

    set_block_timestamp(2000);

    let result = test_env.controller.commit(commitment);

    assert!(matches!(
        result,
        Err(RegistrarControllerError::UnexpiredCommitmentExists { .. })
    ));
}

#[ink::test]
fn test_transfer_ownership_reverts_for_non_owner() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);

    let result = test_env.controller.transfer_ownership(accounts.charlie);

    assert!(matches!(result, Err(RegistrarControllerError::NotOwner)));
}

#[ink::test]
fn test_register_reverts_without_commitment() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    test_env.pop_rules.set_user_pop_status(PopStatus::NoStatus);
    set_block_timestamp(10000);

    let registration = Registration {
        label: String::from("longername01"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: true,
    };

    let result = test_env.controller.register(registration);

    assert!(matches!(
        result,
        Err(RegistrarControllerError::CommitmentNotFound { .. })
    ));
}

#[ink::test]
fn test_register_reverts_when_commitment_too_new() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    test_env.pop_rules.set_user_pop_status(PopStatus::NoStatus);
    set_block_timestamp(10000);

    let registration = Registration {
        label: String::from("longername01"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: true,
    };

    let commitment = test_env.controller.make_commitment(registration.clone());
    test_env.controller.commit(commitment).unwrap();

    set_block_timestamp(10030);

    let result = test_env.controller.register(registration);

    assert!(matches!(
        result,
        Err(RegistrarControllerError::CommitmentTooNew { .. })
    ));
}

#[ink::test]
fn test_register_reverts_when_commitment_too_old() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    test_env.pop_rules.set_user_pop_status(PopStatus::NoStatus);
    set_block_timestamp(10000);

    let registration = Registration {
        label: String::from("longername01"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: true,
    };

    let commitment = test_env.controller.make_commitment(registration.clone());
    test_env.controller.commit(commitment).unwrap();

    set_block_timestamp(10000 + 3600 + 1);

    let result = test_env.controller.register(registration);

    assert!(matches!(
        result,
        Err(RegistrarControllerError::CommitmentTooOld { .. })
    ));
}

#[ink::test]
fn test_register_reverts_for_short_label() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    test_env.pop_rules.set_user_pop_status(PopStatus::PopFull);
    set_block_timestamp(10000);

    let registration = Registration {
        label: String::from("ab"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: true,
    };

    let commitment = test_env.controller.make_commitment(registration.clone());
    test_env.controller.commit(commitment).unwrap();

    set_block_timestamp(10000 + 61);

    let result = test_env.controller.register(registration);

    assert!(matches!(
        result,
        Err(RegistrarControllerError::NameNotAvailable { .. })
    ));
}

#[ink::test]
fn test_register_reverts_with_insufficient_value_for_no_status_user() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    test_env.pop_rules.set_user_pop_status(PopStatus::NoStatus);

    let registration = Registration {
        label: String::from("longername01"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: true,
    };

    commit_and_advance(&mut test_env, &registration, accounts.bob, 10000);
    set_value_transferred(0);

    let result = test_env.controller.register(registration);

    assert!(matches!(
        result,
        Err(RegistrarControllerError::InsufficientValue)
    ));
}

#[ink::test]
fn test_register_reverts_for_reserved_name() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    test_env.pop_rules.set_user_pop_status(PopStatus::PopFull);

    let registration = Registration {
        label: String::from("short"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: true,
    };

    commit_and_advance(&mut test_env, &registration, accounts.bob, 10000);

    let result = test_env.controller.register(registration);

    assert!(matches!(result, Err(RegistrarControllerError::CallFailed)));
}

#[ink::test]
fn test_register_reverts_for_reserved_name_even_with_pop_full() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    test_env.pop_rules.set_user_pop_status(PopStatus::PopFull);

    let registration = Registration {
        label: String::from("abc"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: true,
    };

    commit_and_advance(&mut test_env, &registration, accounts.bob, 10000);

    let result = test_env.controller.register(registration);

    assert!(matches!(result, Err(RegistrarControllerError::CallFailed)));
}

#[ink::test]
fn test_register_reverts_when_pop_full_required_but_user_has_no_status() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    test_env.pop_rules.set_user_pop_status(PopStatus::NoStatus);

    let registration = Registration {
        label: String::from("testnam"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: true,
    };

    commit_and_advance(&mut test_env, &registration, accounts.bob, 10000);
    set_value_transferred(10_000_000);

    let result = test_env.controller.register(registration);

    assert!(matches!(result, Err(RegistrarControllerError::CallFailed)));
}

#[ink::test]
fn test_register_reverts_when_pop_full_required_but_user_has_pop_lite() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    test_env.pop_rules.set_user_pop_status(PopStatus::PopLite);

    let registration = Registration {
        label: String::from("testnam"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: true,
    };

    commit_and_advance(&mut test_env, &registration, accounts.bob, 10000);

    let result = test_env.controller.register(registration);

    assert!(matches!(result, Err(RegistrarControllerError::CallFailed)));
}

#[ink::test]
fn test_register_reverts_when_pop_lite_required_but_user_has_no_status() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    test_env.pop_rules.set_user_pop_status(PopStatus::NoStatus);

    let registration = Registration {
        label: String::from("testna01"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: true,
    };

    commit_and_advance(&mut test_env, &registration, accounts.bob, 10000);
    set_value_transferred(10_000_000);

    let result = test_env.controller.register(registration);

    assert!(matches!(result, Err(RegistrarControllerError::CallFailed)));
}

#[ink::test]
fn test_register_reserved_reverts_without_commitment() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    set_block_timestamp(10000);

    let registration = Registration {
        label: String::from("longername01"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: true,
    };

    let result = test_env.controller.register_reserved(registration);

    assert!(matches!(
        result,
        Err(RegistrarControllerError::CommitmentNotFound { .. })
    ));
}

#[ink::test]
fn test_register_reserved_reverts_when_commitment_too_new() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    set_block_timestamp(10000);

    let registration = Registration {
        label: String::from("longername01"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: true,
    };

    let commitment = test_env.controller.make_commitment(registration.clone());
    test_env.controller.commit(commitment).unwrap();

    set_block_timestamp(10030);

    let result = test_env.controller.register_reserved(registration);

    assert!(matches!(
        result,
        Err(RegistrarControllerError::CommitmentTooNew { .. })
    ));
}

#[ink::test]
fn test_register_reserved_reverts_when_commitment_too_old() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    set_block_timestamp(10000);

    let registration = Registration {
        label: String::from("longername01"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: true,
    };

    let commitment = test_env.controller.make_commitment(registration.clone());
    test_env.controller.commit(commitment).unwrap();

    set_block_timestamp(10000 + 3600 + 1);

    let result = test_env.controller.register_reserved(registration);

    assert!(matches!(
        result,
        Err(RegistrarControllerError::CommitmentTooOld { .. })
    ));
}

#[ink::test]
fn test_register_reserved_reverts_for_short_label() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    set_block_timestamp(10000);

    let registration = Registration {
        label: String::from("ab"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: true,
    };

    let commitment = test_env.controller.make_commitment(registration.clone());
    test_env.controller.commit(commitment).unwrap();

    set_block_timestamp(10000 + 61);

    let result = test_env.controller.register_reserved(registration);

    assert!(matches!(
        result,
        Err(RegistrarControllerError::NameNotAvailable { .. })
    ));
}

#[ink::test]
fn test_register_reverts_with_wrong_secret() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    test_env.pop_rules.set_user_pop_status(PopStatus::NoStatus);
    set_block_timestamp(10000);

    let registration = Registration {
        label: String::from("longername01"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: true,
    };

    let commitment = test_env.controller.make_commitment(registration);
    test_env.controller.commit(commitment).unwrap();

    set_block_timestamp(10000 + 61);

    let wrong_registration = Registration {
        label: String::from("longername01"),
        owner: accounts.bob,
        secret: hash_bytes(b"wrong_secret"),
        reserved: true,
    };

    let result = test_env.controller.register(wrong_registration);

    assert!(matches!(
        result,
        Err(RegistrarControllerError::CommitmentNotFound { .. })
    ));
}

#[ink::test]
fn test_register_reverts_with_wrong_owner() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    test_env.pop_rules.set_user_pop_status(PopStatus::NoStatus);
    set_block_timestamp(10000);

    let registration = Registration {
        label: String::from("longername01"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: true,
    };

    let commitment = test_env.controller.make_commitment(registration);
    test_env.controller.commit(commitment).unwrap();

    set_block_timestamp(10000 + 61);

    let wrong_registration = Registration {
        label: String::from("longername01"),
        owner: accounts.charlie,
        secret: hash_bytes(b"secret"),
        reserved: true,
    };

    let result = test_env.controller.register(wrong_registration);

    assert!(matches!(
        result,
        Err(RegistrarControllerError::CommitmentNotFound { .. })
    ));
}

#[ink::test]
fn test_register_reverts_with_wrong_label() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    test_env.pop_rules.set_user_pop_status(PopStatus::NoStatus);
    set_block_timestamp(10000);

    let registration = Registration {
        label: String::from("longername01"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: true,
    };

    let commitment = test_env.controller.make_commitment(registration);
    test_env.controller.commit(commitment).unwrap();

    set_block_timestamp(10000 + 61);

    let wrong_registration = Registration {
        label: String::from("wrongername01"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: true,
    };

    let result = test_env.controller.register(wrong_registration);

    assert!(matches!(
        result,
        Err(RegistrarControllerError::CommitmentNotFound { .. })
    ));
}

#[ink::test]
fn test_register_reverts_with_wrong_reserved_flag() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.bob);
    test_env.pop_rules.set_user_pop_status(PopStatus::NoStatus);
    set_block_timestamp(10000);

    let registration = Registration {
        label: String::from("longername01"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: true,
    };

    let commitment = test_env.controller.make_commitment(registration);
    test_env.controller.commit(commitment).unwrap();

    set_block_timestamp(10000 + 61);

    let wrong_registration = Registration {
        label: String::from("longername01"),
        owner: accounts.bob,
        secret: hash_bytes(b"secret"),
        reserved: false,
    };

    let result = test_env.controller.register(wrong_registration);

    assert!(matches!(
        result,
        Err(RegistrarControllerError::CommitmentNotFound { .. })
    ));
}
