use crate::dotns_registrar::{DotnsRegistrar, ERC721Error};
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
fn test_add_controller_reverts_not_owner() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    set_caller(acc.bob);
    assert_eq!(
        registrar.add_controller(acc.charlie),
        Err(RegistrarError::NotOwner)
    );
}

#[ink::test]
fn test_remove_controller_reverts_not_owner() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    set_caller(acc.alice);
    registrar.add_controller(acc.bob).unwrap();
    set_caller(acc.charlie);
    assert_eq!(
        registrar.remove_controller(acc.bob),
        Err(RegistrarError::NotOwner)
    );
}

#[ink::test]
fn test_register_reverts_not_controller() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token_id = token_id_from_label("testname");
    set_caller(acc.bob);
    assert_eq!(
        registrar.register(token_id, acc.charlie),
        Err(RegistrarError::NotController { caller: acc.bob })
    );
}

#[ink::test]
fn test_register_reverts_name_not_available() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token_id = token_id_from_label("takenname");
    set_caller(acc.alice);
    registrar.add_controller(acc.bob).unwrap();
    set_caller(acc.bob);
    registrar.register(token_id, acc.charlie).unwrap();
    assert_eq!(
        registrar.register(token_id, acc.django),
        Err(RegistrarError::NameNotAvailable { token_id })
    );
}

#[ink::test]
fn test_transfer_ownership_reverts_not_owner() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    set_caller(acc.bob);
    assert_eq!(
        registrar.transfer_ownership(acc.charlie),
        Err(RegistrarError::NotOwner)
    );
}

#[ink::test]
fn test_approve_reverts_token_not_found() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token_id = token_id_from_label("nonexistent");
    set_caller(acc.alice);
    assert_eq!(
        registrar.approve(acc.bob, token_id),
        Err(ERC721Error::TokenNotFound)
    );
}

#[ink::test]
fn test_approve_reverts_not_owner_or_approved() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token_id = token_id_from_label("ownedname");
    set_caller(acc.alice);
    registrar.add_controller(acc.bob).unwrap();
    set_caller(acc.bob);
    registrar.register(token_id, acc.charlie).unwrap();
    set_caller(acc.django);
    assert_eq!(
        registrar.approve(acc.eve, token_id),
        Err(ERC721Error::NotOwnerOrApproved)
    );
}

#[ink::test]
fn test_approve_reverts_approval_to_current_owner() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token_id = token_id_from_label("selfapprove");
    set_caller(acc.alice);
    registrar.add_controller(acc.bob).unwrap();
    set_caller(acc.bob);
    registrar.register(token_id, acc.charlie).unwrap();
    set_caller(acc.charlie);
    assert_eq!(
        registrar.approve(acc.charlie, token_id),
        Err(ERC721Error::ApprovalToCurrentOwner)
    );
}

#[ink::test]
fn test_transfer_from_reverts_token_not_found() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token_id = token_id_from_label("nonexistent");
    set_caller(acc.alice);
    assert_eq!(
        registrar.transfer_from(acc.alice, acc.bob, token_id),
        Err(ERC721Error::TokenNotFound)
    );
}

#[ink::test]
fn test_transfer_from_reverts_not_owner_or_approved() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token_id = token_id_from_label("transfername");
    set_caller(acc.alice);
    registrar.add_controller(acc.bob).unwrap();
    set_caller(acc.bob);
    registrar.register(token_id, acc.charlie).unwrap();
    set_caller(acc.django);
    assert_eq!(
        registrar.transfer_from(acc.charlie, acc.eve, token_id),
        Err(ERC721Error::NotOwnerOrApproved)
    );
}

#[ink::test]
fn test_transfer_from_reverts_wrong_from_address() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token_id = token_id_from_label("wrongfrom");
    set_caller(acc.alice);
    registrar.add_controller(acc.bob).unwrap();
    set_caller(acc.bob);
    registrar.register(token_id, acc.charlie).unwrap();
    set_caller(acc.charlie);
    assert_eq!(
        registrar.transfer_from(acc.django, acc.eve, token_id),
        Err(ERC721Error::NotOwnerOrApproved)
    );
}

#[ink::test]
fn test_transfer_from_reverts_to_zero_address() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token_id = token_id_from_label("zeroaddress");
    set_caller(acc.alice);
    registrar.add_controller(acc.bob).unwrap();
    set_caller(acc.bob);
    registrar.register(token_id, acc.charlie).unwrap();
    set_caller(acc.charlie);
    assert_eq!(
        registrar.transfer_from(acc.charlie, H160::zero(), token_id),
        Err(ERC721Error::TransferToZeroAddress)
    );
}

#[ink::test]
fn test_safe_transfer_from_reverts_token_not_found() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token_id = token_id_from_label("nonexistent");
    set_caller(acc.alice);
    assert_eq!(
        registrar.safe_transfer_from(acc.alice, acc.bob, token_id),
        Err(ERC721Error::TokenNotFound)
    );
}

#[ink::test]
fn test_safe_transfer_from_reverts_not_owner_or_approved() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token_id = token_id_from_label("safetransfer");
    set_caller(acc.alice);
    registrar.add_controller(acc.bob).unwrap();
    set_caller(acc.bob);
    registrar.register(token_id, acc.charlie).unwrap();
    set_caller(acc.django);
    assert_eq!(
        registrar.safe_transfer_from(acc.charlie, acc.eve, token_id),
        Err(ERC721Error::NotOwnerOrApproved)
    );
}

#[ink::test]
fn test_safe_transfer_from_with_data_reverts_token_not_found() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token_id = token_id_from_label("nonexistent");
    set_caller(acc.alice);
    assert_eq!(
        registrar.safe_transfer_from_with_data(acc.alice, acc.bob, token_id, vec![0x01, 0x02]),
        Err(ERC721Error::TokenNotFound)
    );
}

#[ink::test]
fn test_safe_transfer_from_with_data_reverts_not_owner_or_approved() {
    let mut registrar = setup_registrar();
    let acc = accounts();
    let token_id = token_id_from_label("safetransferdata");
    set_caller(acc.alice);
    registrar.add_controller(acc.bob).unwrap();
    set_caller(acc.bob);
    registrar.register(token_id, acc.charlie).unwrap();
    set_caller(acc.django);
    assert_eq!(
        registrar.safe_transfer_from_with_data(acc.charlie, acc.eve, token_id, vec![0x01, 0x02]),
        Err(ERC721Error::NotOwnerOrApproved)
    );
}
