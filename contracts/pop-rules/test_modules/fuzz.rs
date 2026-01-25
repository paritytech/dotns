use ink::prelude::string::String;
use ink::prelude::vec::Vec;
use ink::H160;

use crate::base_pop_rules::{BaseDotnsPopRules, PopStatus};
use crate::dotns_pop_rules::DotnsPopRules;

use ink_fuzzer::{fuzz, Context};

fn default_accounts() -> ink::env::test::DefaultAccounts {
    ink::env::test::default_accounts()
}

fn set_environment_caller(caller: H160) {
    ink::env::test::set_caller(caller);
}

fn set_environment_block_timestamp(timestamp: u64) {
    ink::env::test::set_block_timestamp::<ink::env::DefaultEnvironment>(timestamp);
}

fn create_contract(starting_price: u128) -> DotnsPopRules {
    let accounts = default_accounts();
    set_environment_caller(accounts.alice);
    DotnsPopRules::new(starting_price)
}

fn ascii_lowercase_string(input_bytes: &[u8]) -> String {
    // Always return a non-empty ASCII string so fuzzer shrink-to-empty cannot panic later.
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
    // target_length must be >= 1 by construction in callers.
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

fn build_name_with_trailing_digits(
    base: &str,
    trailing_digits_seed: u8,
    digit_value_seed: u8,
) -> String {
    let trailing_digits_count = (trailing_digits_seed % 4) as usize;
    let digit_byte = b'0' + (digit_value_seed % 10);

    let mut output_bytes = base.as_bytes().to_vec();
    for _ in 0..trailing_digits_count {
        output_bytes.push(digit_byte);
    }

    String::from_utf8(output_bytes).unwrap_or_else(|_| String::from(base))
}

fn expected_classification_for_base_length_and_trailing_digits(
    base_length: usize,
    trailing_digits: usize,
) -> PopStatus {
    // Mirrors PopRules::classify_name.
    if base_length <= 5 {
        return PopStatus::Reserved;
    }

    if (6..=8).contains(&base_length) {
        if trailing_digits == 2 {
            return PopStatus::PopLite;
        }
        return PopStatus::PopFull;
    }

    if trailing_digits == 2 {
        return PopStatus::NoStatus;
    }

    PopStatus::PopFull
}

fn compute_base_length_and_trailing_digits(name: &String) -> (usize, usize) {
    let total_character_length = name.chars().count();

    let name_bytes = name.as_bytes();
    let mut trailing_digits_count: usize = 0;

    for byte_index in (0..name_bytes.len()).rev() {
        let byte_value = name_bytes[byte_index];
        if (b'0'..=b'9').contains(&byte_value) {
            trailing_digits_count += 1;
        } else {
            break;
        }
    }

    let base_length = total_character_length.saturating_sub(trailing_digits_count);
    (base_length, trailing_digits_count)
}

#[fuzz(cases = 256)]
fn fuzz_classify_rejects_more_than_two_trailing_digits(
    context: Context,
    base_bytes: Vec<u8>,
    trailing_digits_seed: u8,
    digit_value_seed: u8,
) {
    let context = context;
    context.apply();

    let base_string = ascii_lowercase_string(&base_bytes);
    let name =
        build_name_with_trailing_digits(&base_string, trailing_digits_seed, digit_value_seed);

    let (_base_length, trailing_digits_count) = compute_base_length_and_trailing_digits(&name);

    let contract = create_contract(1_000_000);
    let classification_result = contract.classify_name(name);

    if trailing_digits_count > 2 {
        assert!(classification_result.is_err());
    } else {
        assert!(classification_result.is_ok());
    }
}

#[fuzz(cases = 512)]
fn fuzz_classify_matches_expected_matrix(
    context: Context,
    base_bytes: Vec<u8>,
    trailing_digits_seed: u8,
    digit_value_seed: u8,
) {
    let context = context;
    context.apply();

    // We need to force base length between 1 and 20 to cover all branches.
    let base_string_full = ascii_lowercase_string(&base_bytes);
    let base_length_target = 1 + (base_string_full.len() % 20);
    let base_string = normalize_ascii_label_to_length(base_string_full, base_length_target);

    // We need toforce trailing digits count within 0..=2 for OK path.
    let trailing_digits_count = (trailing_digits_seed % 3) as usize;

    let digit_character = (b'0' + (digit_value_seed % 10)) as char;
    let mut name = base_string.clone();
    for _ in 0..trailing_digits_count {
        name.push(digit_character);
    }

    let (base_length, parsed_trailing_digits) = compute_base_length_and_trailing_digits(&name);
    assert_eq!(parsed_trailing_digits, trailing_digits_count);

    let expected = expected_classification_for_base_length_and_trailing_digits(
        base_length,
        trailing_digits_count,
    );

    let contract = create_contract(1_000_000);
    let classification = contract
        .classify_name(name)
        .expect("classify_name must succeed for <= 2 trailing digits");

    assert_eq!(classification.requirement, expected);
}

#[fuzz(cases = 256)]
fn fuzz_price_bounds_and_shape(context: Context, starting_price_factor: u8, name_bytes: Vec<u8>) {
    let context = context;
    context.apply();

    let starting_price = 1_000u128 * (1 + (starting_price_factor as u128));
    let contract = create_contract(starting_price);

    // Keep name length between 1 and 32.
    let name_string_full = ascii_lowercase_string(&name_bytes);
    let name_length_target = 1 + (name_string_full.len() % 32);
    let name = normalize_ascii_label_to_length(name_string_full, name_length_target);

    let price = contract.price(name.clone());
    let name_length = name.chars().count();

    if name_length < 9 {
        assert_eq!(price, 0);
        return;
    }

    if name_length >= 15 {
        assert_eq!(price, starting_price / 2);
        return;
    }

    let expected_price = starting_price * (15u128 - (name_length as u128));
    assert_eq!(price, expected_price);
}

#[fuzz(cases = 256)]
fn fuzz_price_monotonic_for_mid_range(
    context: Context,
    starting_price_factor: u8,
    base_bytes: Vec<u8>,
    length_a_seed: u8,
    length_b_seed: u8,
) {
    let context = context;
    context.apply();

    let starting_price = 1_000u128 * (1 + (starting_price_factor as u128));
    let contract = create_contract(starting_price);

    // Compare two lengths within 9..=14.
    let first_length = 9 + (length_a_seed as usize % 6);
    let second_length = 9 + (length_b_seed as usize % 6);

    let base_string = ascii_lowercase_string(&base_bytes);
    let base_bytes = base_string.as_bytes();

    let first_name = {
        let mut name = String::new();
        for byte_index in 0..first_length {
            name.push(base_bytes[byte_index % base_bytes.len()] as char);
        }
        name
    };

    let second_name = {
        let mut name = String::new();
        for byte_index in 0..second_length {
            name.push(base_bytes[byte_index % base_bytes.len()] as char);
        }
        name
    };

    let first_price = contract.price(first_name);
    let second_price = contract.price(second_name);

    // In 9..=14: shorter name => higher price.
    if first_length < second_length {
        assert!(first_price > second_price);
    } else if first_length > second_length {
        assert!(first_price < second_price);
    } else {
        assert_eq!(first_price, second_price);
    }
}

#[fuzz(cases = 128)]
fn fuzz_reservation_blocks_non_owner_in_price_with_check(
    context: Context,
    base_bytes: Vec<u8>,
    digit_value_seed: u8,
) {
    let context = context;
    context.apply();

    let accounts = default_accounts();
    let mut contract = create_contract(1_000_000);

    // Owner (alice) sets registry controller.
    set_environment_caller(accounts.alice);
    contract
        .update_registry(accounts.alice)
        .expect("update_registry must succeed for owner");

    // Pick a base length 6..=8.
    let base_string_full = ascii_lowercase_string(&base_bytes);
    let base_length_target = 6 + (base_string_full.len() % 3);
    let base_name = normalize_ascii_label_to_length(base_string_full, base_length_target);

    // Build a Lite-eligible name: base length 6..=8 with exactly 2 trailing digits.
    let digit_character = (b'0' + (digit_value_seed % 10)) as char;
    let lite_eligible_name = {
        let mut name = base_name.clone();
        name.push(digit_character);
        name.push(digit_character);
        name
    };

    // Reserve under bob (registry controller is alice).
    set_environment_caller(accounts.alice);
    contract
        .reserve_base_name(lite_eligible_name, accounts.bob)
        .expect("reserve_base_name must succeed for lite-eligible names");

    let reservation_status = contract.is_base_name_reserved(base_name.clone());
    assert!(reservation_status.is_reserved);
    assert_eq!(reservation_status.owner, accounts.bob);

    // Non-owner should be blocked by reservation enforcement.
    let result = contract.price_with_check(base_name, accounts.charlie);
    assert!(result.is_err());
}

#[fuzz(cases = 128)]
fn fuzz_reservation_owner_can_continue_pricing_checks(
    context: Context,
    base_bytes: Vec<u8>,
    digit_value_seed: u8,
) {
    let context = context;
    context.apply();

    let accounts = default_accounts();
    let mut contract = create_contract(1_000_000);

    set_environment_caller(accounts.alice);
    contract
        .update_registry(accounts.alice)
        .expect("update_registry must succeed for owner");

    let base_string_full = ascii_lowercase_string(&base_bytes);
    let base_length_target = 6 + (base_string_full.len() % 3);
    let base_name = normalize_ascii_label_to_length(base_string_full, base_length_target);

    let digit_character = (b'0' + (digit_value_seed % 10)) as char;
    let lite_eligible_name = {
        let mut name = base_name.clone();
        name.push(digit_character);
        name.push(digit_character);
        name
    };

    set_environment_caller(accounts.alice);
    contract
        .reserve_base_name(lite_eligible_name, accounts.bob)
        .expect("reserve_base_name must succeed");

    // Reservation owner should not be blocked by the reservation rule.
    let result = contract.price_with_check(base_name, accounts.bob);

    if let Err(error) = result {
        let error_string = format!("{:?}", error);
        assert!(
            !error_string.contains("Base name reserved for original Lite registrant"),
            "reservation owner must not be blocked by reservation rule"
        );
    }
}

#[fuzz(cases = 128)]
fn fuzz_reservation_expires_allows_others(
    context: Context,
    base_bytes: Vec<u8>,
    digit_value_seed: u8,
    time_seed: u64,
) {
    let context = context;
    context.apply();

    let accounts = default_accounts();
    let mut contract = create_contract(1_000_000);

    set_environment_caller(accounts.alice);
    contract
        .update_registry(accounts.alice)
        .expect("update_registry must succeed for owner");

    let base_string_full = ascii_lowercase_string(&base_bytes);
    let base_length_target = 6 + (base_string_full.len() % 3);
    let base_name = normalize_ascii_label_to_length(base_string_full, base_length_target);

    let digit_character = (b'0' + (digit_value_seed % 10)) as char;
    let lite_eligible_name = {
        let mut name = base_name.clone();
        name.push(digit_character);
        name.push(digit_character);
        name
    };

    // Reserve at timestamp T0.
    let initial_timestamp = 1_000u64 + (time_seed % 10_000u64);
    set_environment_block_timestamp(initial_timestamp);

    set_environment_caller(accounts.alice);
    contract
        .reserve_base_name(lite_eligible_name, accounts.bob)
        .expect("reserve_base_name must succeed");

    let reserved_status = contract.is_base_name_reserved(base_name.clone());
    assert!(reserved_status.is_reserved);

    // Move time forward beyond MAX_RESERVATION_TIME (12 weeks = 7_257_600 seconds).
    let after_expiry_timestamp = initial_timestamp + 7_257_600 + 1;
    set_environment_block_timestamp(after_expiry_timestamp);

    let status_after = contract.is_base_name_reserved(base_name.clone());
    assert!(!status_after.is_reserved);

    // Others should no longer be blocked by reservation enforcement.
    let result = contract.price_with_check(base_name, accounts.charlie);

    if let Err(error) = result {
        let error_string = format!("{:?}", error);
        assert!(
            !error_string.contains("Base name reserved for original Lite registrant"),
            "after expiry, reservation rule must not block other users"
        );
    }
}
