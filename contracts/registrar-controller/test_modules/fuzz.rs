use crate::dotns_registrar_controller::DotnsRegistrarController;
use crate::registrar_controller::{
    BaseDotnsRegistrarController, RegistrarControllerError, Registration,
};
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
use ink_fuzzer::{fuzz, Context};

const CONTROLLER_ADDR: [u8; 20] = [0xCC; 20];

struct TestEnv {
    controller: DotnsRegistrarController,
    controller_addr: H160,
}

fn default_accounts() -> test::DefaultAccounts {
    test::default_accounts()
}

fn set_caller(caller: H160) {
    test::set_caller(caller);
}

fn set_callee(callee: H160) {
    test::set_callee(callee);
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

fn ascii_lowercase_string(input_bytes: &[u8]) -> String {
    if input_bytes.is_empty() {
        return String::from("a");
    }

    let mut output_bytes: Vec<u8> = Vec::with_capacity(input_bytes.len());
    for byte_value in input_bytes {
        output_bytes.push(b'a' + (byte_value % 26));
    }

    String::from_utf8(output_bytes).unwrap_or_else(|_| String::from("a"))
}

fn normalize_ascii_label_to_length(mut label: String, target_length: usize) -> String {
    if label.is_empty() {
        label.push('a');
    }

    if label.len() >= target_length {
        label.truncate(target_length);
        return label;
    }

    while label.len() < target_length {
        label.push('a');
    }

    label
}

fn create_no_status_label(seed: &[u8], digit_seed: u8) -> String {
    let base = ascii_lowercase_string(seed);
    let base = normalize_ascii_label_to_length(base, 9 + (seed.first().unwrap_or(&0) % 4) as usize);
    let digit = (b'0' + (digit_seed % 10)) as char;
    let mut label = base;
    label.push(digit);
    label.push(digit);
    label
}

fn create_short_label(seed: &[u8]) -> String {
    let base = ascii_lowercase_string(seed);
    let len = 1 + (seed.first().unwrap_or(&0) % 2) as usize;
    normalize_ascii_label_to_length(base, len)
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

    let mut registrar = DotnsRegistrarRef::new(String::from("DotNS"), String::from("DNS"))
        .code_hash(registrar_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([0u8; 32]))
        .instantiate();

    let mut reverse_resolver = DotnsReverseResolverRef::new()
        .code_hash(reverse_resolver_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([2u8; 32]))
        .instantiate();

    let store_factory = StoreFactoryRef::new(store_code_hash)
        .code_hash(store_factory_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([4u8; 32]))
        .instantiate();

    let mut registry = DotnsRegistryRef::new(reverse_resolver.clone(), store_factory.clone())
        .code_hash(registry_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([1u8; 32]))
        .instantiate();

    let mut pop_rules = DotnsPopRulesRef::new(1_000_000u128)
        .code_hash(pop_rules_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([3u8; 32]))
        .instantiate();

    let controller_addr: H160 = CONTROLLER_ADDR.into();
    set_callee(controller_addr);

    let controller = DotnsRegistrarController::new(
        registrar.clone(),
        registry.clone(),
        reverse_resolver.clone(),
        pop_rules.clone(),
        store_factory,
        60,
        3600,
    )
    .unwrap();

    reverse_resolver
        .update_registrar_controller(controller_addr)
        .unwrap();
    pop_rules.update_registry(controller_addr).unwrap();
    registrar.add_controller(controller_addr).unwrap();
    registry
        .update_registrar_controller(controller_addr)
        .unwrap();

    TestEnv {
        controller,
        controller_addr,
    }
}

#[fuzz(cases = 256)]
fn fuzz_register_fails_without_commitment(
    fuzz_context: Context,
    owner_seed: u8,
    secret_bytes: Vec<u8>,
    label_bytes: Vec<u8>,
    digit_seed: u8,
) {
    fuzz_context.apply();

    let mut test_env = setup_test_env();
    let owner = select_account(owner_seed);
    let secret = hash_bytes(&secret_bytes);
    let label = create_no_status_label(&label_bytes, digit_seed);

    set_caller(owner);
    set_callee(test_env.controller_addr);
    set_block_timestamp(10000);
    set_value_transferred(10_000_000);

    let registration = Registration {
        label,
        owner,
        secret,
        reserved: false,
    };

    let result = test_env.controller.register(registration);

    assert!(matches!(
        result,
        Err(RegistrarControllerError::CommitmentNotFound { .. })
    ));
}

#[fuzz(cases = 256)]
fn fuzz_register_fails_when_commitment_too_new(
    fuzz_context: Context,
    owner_seed: u8,
    secret_bytes: Vec<u8>,
    label_bytes: Vec<u8>,
    digit_seed: u8,
    time_offset: u64,
) {
    fuzz_context.apply();

    let mut test_env = setup_test_env();
    let owner = select_account(owner_seed);
    let secret = hash_bytes(&secret_bytes);
    let label = create_no_status_label(&label_bytes, digit_seed);

    let commit_time: u64 = 10000;
    set_caller(owner);
    set_callee(test_env.controller_addr);
    set_block_timestamp(commit_time);

    let registration = Registration {
        label,
        owner,
        secret,
        reserved: false,
    };
    let commitment = test_env.controller.make_commitment(registration.clone());
    test_env.controller.commit(commitment).unwrap();

    let min_age = test_env.controller.min_commitment_age();
    let bounded_offset = time_offset % min_age;
    set_block_timestamp(commit_time + bounded_offset);
    set_value_transferred(10_000_000);

    let result = test_env.controller.register(registration);

    assert!(matches!(
        result,
        Err(RegistrarControllerError::CommitmentTooNew { .. })
    ));
}

#[fuzz(cases = 256)]
fn fuzz_register_fails_when_commitment_too_old(
    fuzz_context: Context,
    owner_seed: u8,
    secret_bytes: Vec<u8>,
    label_bytes: Vec<u8>,
    digit_seed: u8,
    extra_time: u64,
) {
    fuzz_context.apply();

    let mut test_env = setup_test_env();
    let owner = select_account(owner_seed);
    let secret = hash_bytes(&secret_bytes);
    let label = create_no_status_label(&label_bytes, digit_seed);

    let commit_time: u64 = 10000;
    set_caller(owner);
    set_callee(test_env.controller_addr);
    set_block_timestamp(commit_time);

    let registration = Registration {
        label,
        owner,
        secret,
        reserved: false,
    };
    let commitment = test_env.controller.make_commitment(registration.clone());
    test_env.controller.commit(commitment).unwrap();

    let max_age = test_env.controller.max_commitment_age();
    let bounded_extra = (extra_time % 10000) + 1;
    set_block_timestamp(commit_time + max_age + bounded_extra);
    set_value_transferred(10_000_000);

    let result = test_env.controller.register(registration);

    assert!(matches!(
        result,
        Err(RegistrarControllerError::CommitmentTooOld { .. })
    ));
}

#[fuzz(cases = 256)]
fn fuzz_no_status_user_register_fails_with_insufficient_value(
    fuzz_context: Context,
    owner_seed: u8,
    secret_bytes: Vec<u8>,
    label_bytes: Vec<u8>,
    digit_seed: u8,
    insufficient_value: u64,
) {
    fuzz_context.apply();

    let mut test_env = setup_test_env();
    let owner = select_account(owner_seed);
    let secret = hash_bytes(&secret_bytes);
    let label = create_no_status_label(&label_bytes, digit_seed);

    let commit_time: u64 = 10000;
    set_caller(owner);
    set_callee(test_env.controller_addr);
    set_block_timestamp(commit_time);

    let registration = Registration {
        label,
        owner,
        secret,
        reserved: false,
    };
    let commitment = test_env.controller.make_commitment(registration.clone());
    test_env.controller.commit(commitment).unwrap();

    let min_age = test_env.controller.min_commitment_age();
    set_block_timestamp(commit_time + min_age + 1);

    let bounded_value = (insufficient_value as u128) % 1_000_000;
    set_value_transferred(bounded_value);

    let result = test_env.controller.register(registration);

    assert!(matches!(
        result,
        Err(RegistrarControllerError::InsufficientValue)
    ));
}

#[fuzz(cases = 256)]
fn fuzz_register_reserved_fails_without_commitment(
    fuzz_context: Context,
    owner_seed: u8,
    secret_bytes: Vec<u8>,
    label_bytes: Vec<u8>,
    digit_seed: u8,
) {
    fuzz_context.apply();

    let mut test_env = setup_test_env();
    let owner = select_account(owner_seed);
    let secret = hash_bytes(&secret_bytes);
    let label = create_no_status_label(&label_bytes, digit_seed);

    set_caller(owner);
    set_callee(test_env.controller_addr);
    set_block_timestamp(10000);

    let registration = Registration {
        label,
        owner,
        secret,
        reserved: true,
    };

    let result = test_env.controller.register_reserved(registration);

    assert!(matches!(
        result,
        Err(RegistrarControllerError::CommitmentNotFound { .. })
    ));
}

#[fuzz(cases = 256)]
fn fuzz_register_reserved_fails_when_commitment_too_new(
    fuzz_context: Context,
    owner_seed: u8,
    secret_bytes: Vec<u8>,
    label_bytes: Vec<u8>,
    digit_seed: u8,
    time_offset: u64,
) {
    fuzz_context.apply();

    let mut test_env = setup_test_env();
    let owner = select_account(owner_seed);
    let secret = hash_bytes(&secret_bytes);
    let label = create_no_status_label(&label_bytes, digit_seed);

    let commit_time: u64 = 10000;
    set_caller(owner);
    set_callee(test_env.controller_addr);
    set_block_timestamp(commit_time);

    let registration = Registration {
        label,
        owner,
        secret,
        reserved: true,
    };
    let commitment = test_env.controller.make_commitment(registration.clone());
    test_env.controller.commit(commitment).unwrap();

    let min_age = test_env.controller.min_commitment_age();
    let bounded_offset = time_offset % min_age;
    set_block_timestamp(commit_time + bounded_offset);

    let result = test_env.controller.register_reserved(registration);

    assert!(matches!(
        result,
        Err(RegistrarControllerError::CommitmentTooNew { .. })
    ));
}

#[fuzz(cases = 256)]
fn fuzz_register_reserved_fails_when_commitment_too_old(
    fuzz_context: Context,
    owner_seed: u8,
    secret_bytes: Vec<u8>,
    label_bytes: Vec<u8>,
    digit_seed: u8,
    extra_time: u64,
) {
    fuzz_context.apply();

    let mut test_env = setup_test_env();
    let owner = select_account(owner_seed);
    let secret = hash_bytes(&secret_bytes);
    let label = create_no_status_label(&label_bytes, digit_seed);

    let commit_time: u64 = 10000;
    set_caller(owner);
    set_callee(test_env.controller_addr);
    set_block_timestamp(commit_time);

    let registration = Registration {
        label,
        owner,
        secret,
        reserved: true,
    };
    let commitment = test_env.controller.make_commitment(registration.clone());
    test_env.controller.commit(commitment).unwrap();

    let max_age = test_env.controller.max_commitment_age();
    let bounded_extra = (extra_time % 10000) + 1;
    set_block_timestamp(commit_time + max_age + bounded_extra);

    let result = test_env.controller.register_reserved(registration);

    assert!(matches!(
        result,
        Err(RegistrarControllerError::CommitmentTooOld { .. })
    ));
}

#[fuzz(cases = 256)]
fn fuzz_short_label_fails_availability_check(fuzz_context: Context, label_bytes: Vec<u8>) {
    fuzz_context.apply();

    let test_env = setup_test_env();
    let label = create_short_label(&label_bytes);

    set_callee(test_env.controller_addr);

    let result = test_env.controller.available(label);

    assert!(result.is_err());
}

#[fuzz(cases = 256)]
fn fuzz_non_owner_cannot_transfer_ownership(
    fuzz_context: Context,
    non_owner_seed: u8,
    new_owner_seed: u8,
) {
    fuzz_context.apply();

    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    let non_owner = select_account(non_owner_seed);
    let new_owner = select_account(new_owner_seed);

    if non_owner == accounts.alice {
        return;
    }

    set_caller(non_owner);
    set_callee(test_env.controller_addr);

    let result = test_env.controller.transfer_ownership(new_owner);

    assert!(matches!(result, Err(RegistrarControllerError::NotOwner)));
    assert_eq!(test_env.controller.owner(), accounts.alice);
}
