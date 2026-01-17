use crate::pop_rules::PopRules;
use crate::popbase::{PopRulesBase, PopRulesError};
use ink::prelude::string::String;
use ink::H160;

fn accounts() -> ink::env::test::DefaultAccounts {
    ink::env::test::default_accounts()
}

/// Function used to set a caller much more
/// Readable than having many invocations of the internal
/// Construct
fn set_caller(account: H160) {
    ink::env::test::set_caller(account);
}

/// Creates contract with alice as owner
fn setup_pop_rules() -> PopRules {
    let acc = accounts();
    set_caller(acc.alice);
    PopRules::new(1_000_000)
}

#[ink::test]
fn test_price_with_check_revert_governance() {
    let contract = setup_pop_rules();
    let acc = accounts();

    let result = contract.price_with_check(String::from("hello"), acc.bob);

    assert!(
        matches!(result, Err(PopRulesError::PopError(msg)) if msg == "Reserved for Governance")
    );
}

#[ink::test]
fn test_price_with_check_revert_full_needed() {
    let contract = setup_pop_rules();
    let acc = accounts();

    let result = contract.price_with_check(String::from("alicebob"), acc.bob);

    assert!(matches!(
        result,
        Err(PopRulesError::PopError(msg)) if msg == "Requires Full Personhood verification"
    ));
}

#[ink::test]
fn test_price_with_check_revert_lite_needed() {
    let contract = setup_pop_rules();
    let acc = accounts();

    let result = contract.price_with_check(String::from("lights01"), acc.bob);

    assert!(matches!(
        result,
        Err(PopRulesError::PopError(msg)) if msg == "Requires Personhood Lite verification"
    ));
}

#[ink::test]
fn test_price_with_check_revert_base_reserved() {
    let mut contract = setup_pop_rules();
    let acc = accounts();
    let leonardo = acc.bob;
    let tiago = acc.charlie;

    // alice is already the owner
    set_caller(acc.alice);
    contract
        .update_registry(acc.alice)
        .expect("update_registry failed");

    contract
        .reserve_base_name(String::from("lights01"), leonardo)
        .expect("reserve failed");

    let result = contract.price_with_check(String::from("lights"), tiago);

    assert!(matches!(
        result,
        Err(PopRulesError::PopError(msg)) if msg == "Base name reserved for original Lite registrant"
    ));
}

#[ink::test]
fn test_classify_revert_too_many_digits() {
    let contract = setup_pop_rules();

    let result = contract.classify_name(String::from("name123"));

    assert!(matches!(result, Err(PopRulesError::TooManyTrailingDigits)));
}

#[ink::test]
fn test_reserve_revert_not_registry() {
    let mut contract = setup_pop_rules();
    let acc = accounts();

    set_caller(acc.bob);
    let result = contract.reserve_base_name(String::from("lights01"), acc.bob);

    assert!(matches!(result, Err(PopRulesError::NotRegistry)));
}

#[ink::test]
fn test_reserve_revert_not_lite_eligible() {
    let mut contract = setup_pop_rules();
    let acc = accounts();

    // alice is already the owner
    set_caller(acc.alice);
    contract
        .update_registry(acc.alice)
        .expect("update_registry failed");

    let result = contract.reserve_base_name(String::from("alicebob"), acc.bob);

    assert!(matches!(result, Err(PopRulesError::NotLiteEligible)));
}

#[ink::test]
fn test_update_registry_revert_not_owner() {
    let mut contract = setup_pop_rules();
    let acc = accounts();

    // Call as bob
    set_caller(acc.bob);

    let result = contract.update_registry(acc.charlie);

    assert!(matches!(result, Err(PopRulesError::NotOwner)));
}

#[ink::test]
fn test_set_code_revert_not_owner() {
    let mut contract = setup_pop_rules();
    let acc = accounts();

    set_caller(acc.bob);

    let result = contract.set_code([0u8; 32]);

    assert!(matches!(result, Err(PopRulesError::NotOwner)));
}
