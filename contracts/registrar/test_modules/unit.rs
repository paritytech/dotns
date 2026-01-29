use crate::dotns_registrar::DotnsRegistrar;
use crate::registrar::*;
use ink::env::test;
use ink::prelude::string::String;
use ink::primitives::{H160, U256};

fn accounts() -> test::DefaultAccounts {
    test::default_accounts()
}

fn set_caller(caller: H160) {
    test::set_caller(caller);
}

fn setup_registrar() -> DotnsRegistrar {
    let acc = accounts();
    set_caller(acc.alice);
    DotnsRegistrar::new(String::from("DotNS"), String::from("DNS"))
}

fn token_id_from_label(label: &str) -> U256 {
    use ink::env::hash::{HashOutput, Keccak256};
    let mut output = <Keccak256 as HashOutput>::Type::default();
    ink::env::hash_bytes::<Keccak256>(label.as_bytes(), &mut output);
    U256::from_big_endian(&output)
}

#[ink::test]
fn test_add_controller() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    set_caller(acc.alice);
    registrar.add_controller(acc.bob).unwrap();
    assert!(registrar.is_controller(acc.bob));
}

#[ink::test]
fn test_remove_controller() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    set_caller(acc.alice);
    registrar.add_controller(acc.bob).unwrap();
    registrar.remove_controller(acc.bob).unwrap();
    assert!(!registrar.is_controller(acc.bob));
}

#[ink::test]
fn test_register_mints_to_owner() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token_id = token_id_from_label("alice");
    set_caller(acc.alice);
    registrar.add_controller(acc.charlie).unwrap();
    set_caller(acc.charlie);
    registrar.register(token_id, acc.bob).unwrap();
    assert_eq!(registrar.owner_of(token_id), Some(acc.bob));
    assert_eq!(registrar.balance_of(acc.bob), U256::from(1));
}

#[ink::test]
fn test_register_multiple_same_owner() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token1 = token_id_from_label("nameOne");
    let token2 = token_id_from_label("nameTwo");
    set_caller(acc.alice);
    registrar.add_controller(acc.charlie).unwrap();
    set_caller(acc.charlie);
    registrar.register(token1, acc.bob).unwrap();
    registrar.register(token2, acc.bob).unwrap();
    assert_eq!(registrar.balance_of(acc.bob), U256::from(2));
    assert_eq!(registrar.owner_of(token1), Some(acc.bob));
    assert_eq!(registrar.owner_of(token2), Some(acc.bob));
}

#[ink::test]
fn test_register_multiple_owners() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token1 = token_id_from_label("edName");
    let token2 = token_id_from_label("tiagoName");
    set_caller(acc.alice);
    registrar.add_controller(acc.charlie).unwrap();
    set_caller(acc.charlie);
    registrar.register(token1, acc.bob).unwrap();
    registrar.register(token2, acc.django).unwrap();
    assert_eq!(registrar.balance_of(acc.bob), U256::from(1));
    assert_eq!(registrar.balance_of(acc.django), U256::from(1));
    assert_eq!(registrar.owner_of(token1), Some(acc.bob));
    assert_eq!(registrar.owner_of(token2), Some(acc.django));
}

#[ink::test]
fn test_available_before_after_register() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token_id = token_id_from_label("availabilityCheck");
    set_caller(acc.alice);
    registrar.add_controller(acc.charlie).unwrap();
    assert!(registrar.available(token_id));
    set_caller(acc.charlie);
    registrar.register(token_id, acc.bob).unwrap();
    assert!(!registrar.available(token_id));
}

#[ink::test]
fn test_register_to_contract_address() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token_id = token_id_from_label("contractOwnedName");
    set_caller(acc.alice);
    registrar.add_controller(acc.charlie).unwrap();
    set_caller(acc.charlie);
    registrar.register(token_id, acc.eve).unwrap();
    assert_eq!(registrar.owner_of(token_id), Some(acc.eve));
    assert_eq!(registrar.balance_of(acc.eve), U256::from(1));
}

#[ink::test]
fn test_approve() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token_id = token_id_from_label("approvalName");
    set_caller(acc.alice);
    registrar.add_controller(acc.charlie).unwrap();
    set_caller(acc.charlie);
    registrar.register(token_id, acc.bob).unwrap();
    set_caller(acc.bob);
    registrar.approve(acc.django, token_id).unwrap();
    assert_eq!(registrar.get_approved(token_id), Some(acc.django));
}

#[ink::test]
fn test_set_approval_for_all() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token_id = token_id_from_label("operatorName");
    set_caller(acc.alice);
    registrar.add_controller(acc.charlie).unwrap();
    set_caller(acc.charlie);
    registrar.register(token_id, acc.bob).unwrap();
    set_caller(acc.bob);
    registrar.set_approval_for_all(acc.django, true);
    assert!(registrar.is_approved_for_all(acc.bob, acc.django));
}

#[ink::test]
fn test_transfer_from() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token_id = token_id_from_label("transferName");
    set_caller(acc.alice);
    registrar.add_controller(acc.charlie).unwrap();
    set_caller(acc.charlie);
    registrar.register(token_id, acc.bob).unwrap();
    set_caller(acc.bob);
    registrar
        .transfer_from(acc.bob, acc.django, token_id)
        .unwrap();
    assert_eq!(registrar.owner_of(token_id), Some(acc.django));
    assert_eq!(registrar.balance_of(acc.bob), U256::from(0));
    assert_eq!(registrar.balance_of(acc.django), U256::from(1));
}

#[ink::test]
fn test_transfer_from_approved() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token_id = token_id_from_label("approvedTransfer");
    set_caller(acc.alice);
    registrar.add_controller(acc.eve).unwrap();
    set_caller(acc.eve);
    registrar.register(token_id, acc.bob).unwrap();
    set_caller(acc.bob);
    registrar.approve(acc.charlie, token_id).unwrap();
    set_caller(acc.charlie);
    registrar
        .transfer_from(acc.bob, acc.django, token_id)
        .unwrap();
    assert_eq!(registrar.owner_of(token_id), Some(acc.django));
}

#[ink::test]
fn test_transfer_from_operator() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token_id = token_id_from_label("operatorTransfer");
    set_caller(acc.alice);
    registrar.add_controller(acc.eve).unwrap();
    set_caller(acc.eve);
    registrar.register(token_id, acc.bob).unwrap();
    set_caller(acc.bob);
    registrar.set_approval_for_all(acc.charlie, true);
    set_caller(acc.charlie);
    registrar
        .transfer_from(acc.bob, acc.django, token_id)
        .unwrap();
    assert_eq!(registrar.owner_of(token_id), Some(acc.django));
}

#[ink::test]
fn test_transfer_clears_approval() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token_id = token_id_from_label("clearApproval");
    set_caller(acc.alice);
    registrar.add_controller(acc.eve).unwrap();
    set_caller(acc.eve);
    registrar.register(token_id, acc.bob).unwrap();
    set_caller(acc.bob);
    registrar.approve(acc.charlie, token_id).unwrap();
    registrar
        .transfer_from(acc.bob, acc.django, token_id)
        .unwrap();
    assert_eq!(registrar.get_approved(token_id), None);
}
