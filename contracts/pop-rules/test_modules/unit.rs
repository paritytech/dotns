use crate::base_pop_rules::{BaseDotnsPopRules, PopStatus};
use crate::dotns_pop_rules::DotnsPopRules;
use ink::prelude::string::String;
use ink::H160;

fn accounts() -> ink::env::test::DefaultAccounts {
    ink::env::test::default_accounts()
}

fn set_caller(account: H160) {
    ink::env::test::set_caller(account);
}

fn setup_pop_rules() -> DotnsPopRules {
    let acc = accounts();
    set_caller(acc.alice);
    DotnsPopRules::new(1_000_000)
}

#[ink::test]
fn test_classify_governance() {
    let contract = setup_pop_rules();

    let classification = contract
        .classify_name(String::from("hello"))
        .expect("classify failed");

    assert_eq!(classification.requirement, PopStatus::Reserved);
    assert_eq!(classification.message, "Reserved for Governance");
}

#[ink::test]
fn test_classify_governance_suffix() {
    let contract = setup_pop_rules();

    let classification = contract
        .classify_name(String::from("hello01"))
        .expect("classify failed");

    assert_eq!(classification.requirement, PopStatus::Reserved);
    assert_eq!(classification.message, "Reserved for Governance");
}

#[ink::test]
fn test_classify_lite_requires() {
    let contract = setup_pop_rules();

    let classification = contract
        .classify_name(String::from("lights01"))
        .expect("classify failed");

    assert_eq!(classification.requirement, PopStatus::PopLite);
    assert_eq!(
        classification.message,
        "Requires Light personhood verification"
    );
}

#[ink::test]
fn test_classify_full_requires() {
    let contract = setup_pop_rules();

    let classification = contract
        .classify_name(String::from("alicebob"))
        .expect("classify failed");

    assert_eq!(classification.requirement, PopStatus::PopFull);
    assert_eq!(
        classification.message,
        "Requires Full personhood verification"
    );
}

#[ink::test]
fn test_classify_full_suffix() {
    let contract = setup_pop_rules();

    let classification = contract
        .classify_name(String::from("alicebo1"))
        .expect("classify failed");

    assert_eq!(classification.requirement, PopStatus::PopFull);
    assert_eq!(
        classification.message,
        "Requires Full personhood verification"
    );
}

#[ink::test]
fn test_classify_nostatus_available() {
    let contract = setup_pop_rules();

    let classification = contract
        .classify_name(String::from("longnamehere01"))
        .expect("classify failed");

    assert_eq!(classification.requirement, PopStatus::NoStatus);
    assert_eq!(classification.message, "Available to all");
}

#[ink::test]
fn test_price_with_check_full_allowed_for_lite() {
    let mut contract = setup_pop_rules();
    let acc = accounts();

    set_caller(acc.bob);
    contract.set_user_pop_status(PopStatus::PopFull);

    let metadata = contract
        .price_with_check(String::from("lights01"), acc.bob)
        .expect("price_with_check failed");

    assert_eq!(metadata.status, PopStatus::PopLite);
    assert_eq!(metadata.user_status, PopStatus::PopFull);
}

#[ink::test]
fn test_base_reservation_blocks_others() {
    let mut contract = setup_pop_rules();
    let acc = accounts();
    let leonardo = acc.bob;
    let tiago = acc.charlie;

    // alice is already the owner from setup_pop_rules
    set_caller(acc.alice);
    contract
        .update_registry(acc.alice)
        .expect("update_registry failed");

    contract
        .reserve_base_name(String::from("lights01"), leonardo)
        .expect("reserve failed");

    let status = contract.is_base_name_reserved(String::from("lights"));
    assert!(status.is_reserved);
    assert_eq!(status.owner, leonardo);

    contract
        .reserve_base_name(String::from("lights01"), tiago)
        .expect("reserve failed");

    let status_after = contract.is_base_name_reserved(String::from("lights"));
    assert!(status_after.is_reserved);
    assert_eq!(status_after.owner, leonardo);
    assert_eq!(status_after.expires, status.expires);
}

#[ink::test]
fn test_price_without_check_reserved() {
    let mut contract = setup_pop_rules();
    let acc = accounts();
    let leonardo = acc.bob;
    let tiago = acc.charlie;

    // alice is already the owner from setup_pop_rules
    set_caller(acc.alice);
    contract
        .update_registry(acc.alice)
        .expect("update_registry failed");

    contract
        .reserve_base_name(String::from("lights01"), leonardo)
        .expect("reserve failed");

    let metadata = contract
        .price_without_check(String::from("lights"), tiago)
        .expect("price_without_check failed");

    assert_eq!(metadata.status, PopStatus::Reserved);
    assert_eq!(
        metadata.message,
        "Base name reserved for original Lite registrant"
    );
    assert_eq!(metadata.price, contract.price(String::from("lights")));
}

#[ink::test]
fn test_is_base_name() {
    let contract = setup_pop_rules();

    assert!(contract.is_base_name(String::from("alice")));
    assert!(!contract.is_base_name(String::from("alice99")));
    assert!(contract.is_base_name(String::from("99alice")));
}

#[ink::test]
fn test_price_short_name() {
    let contract = setup_pop_rules();
    assert_eq!(contract.price(String::from("short")), 0);
}

#[ink::test]
fn test_price_long_name() {
    let contract = setup_pop_rules();
    assert_eq!(contract.price(String::from("verylongnamehere")), 500_000);
}

#[ink::test]
fn test_price_mid_length() {
    let contract = setup_pop_rules();
    assert_eq!(contract.price(String::from("ninechars")), 6_000_000);
}
