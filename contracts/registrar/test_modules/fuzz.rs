use crate::dotns_registrar::{DotnsRegistrar, ERC721Error};
use crate::registrar::*;
use ink::prelude::string::String;
use ink::prelude::vec::Vec;
use ink::primitives::{H160, U256};
use ink_fuzzer::{Context, fuzz};

fn default_accounts() -> ink::env::test::DefaultAccounts {
    ink::env::test::default_accounts()
}

fn set_caller(caller: H160) {
    ink::env::test::set_caller(caller);
}

fn create_registrar() -> DotnsRegistrar {
    let accounts = default_accounts();
    set_caller(accounts.alice);
    DotnsRegistrar::new(String::from("DotNS"), String::from("DNS"))
}

fn token_id_from_bytes(bytes: &[u8]) -> U256 {
    use ink::env::hash::{HashOutput, Keccak256};
    let mut output = <Keccak256 as HashOutput>::Type::default();
    ink::env::hash_bytes::<Keccak256>(bytes, &mut output);
    U256::from_big_endian(&output)
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

#[fuzz(cases = 256)]
fn invariant_only_owner_can_manage_controllers(
    context: Context,
    caller_seed: u8,
    controller_seed: u8,
) {
    context.apply();

    let accounts = default_accounts();
    let mut registrar = create_registrar();

    let caller = select_account(caller_seed);
    let controller = select_account(controller_seed);

    set_caller(caller);
    let add = registrar.add_controller(controller);
    let remove = registrar.remove_controller(controller);

    if caller == accounts.alice {
        assert!(add.is_ok());
        assert!(remove.is_ok());
    } else {
        assert_eq!(add, Err(RegistrarError::NotOwner));
        assert_eq!(remove, Err(RegistrarError::NotOwner));
    }
}

#[fuzz(cases = 256)]
fn invariant_only_controller_can_register(
    context: Context,
    caller_seed: u8,
    owner_seed: u8,
    token_bytes: Vec<u8>,
) {
    context.apply();

    let accounts = default_accounts();
    let mut registrar = create_registrar();

    set_caller(accounts.alice);
    registrar.add_controller(accounts.bob).unwrap();

    let caller = select_account(caller_seed);
    let owner = select_account(owner_seed);
    let token_id = token_id_from_bytes(&token_bytes);

    set_caller(caller);
    let result = registrar.register(token_id, owner);

    if caller == accounts.bob {
        assert!(result.is_ok());
    } else {
        assert_eq!(result, Err(RegistrarError::NotController { caller }));
    }
}

#[fuzz(cases = 256)]
fn invariant_name_uniqueness(
    context: Context,
    first_owner_seed: u8,
    second_owner_seed: u8,
    token_bytes: Vec<u8>,
) {
    context.apply();

    let accounts = default_accounts();
    let mut registrar = create_registrar();

    set_caller(accounts.alice);
    registrar.add_controller(accounts.bob).unwrap();

    let token_id = token_id_from_bytes(&token_bytes);
    let first_owner = select_account(first_owner_seed);
    let second_owner = select_account(second_owner_seed);

    set_caller(accounts.bob);
    registrar.register(token_id, first_owner).unwrap();

    let result = registrar.register(token_id, second_owner);

    assert_eq!(result, Err(RegistrarError::NameNotAvailable { token_id }));
}

#[fuzz(cases = 256)]
fn invariant_transfer_authorisation(
    context: Context,
    owner_seed: u8,
    caller_seed: u8,
    to_seed: u8,
    token_bytes: Vec<u8>,
) {
    context.apply();

    let accounts = default_accounts();
    let mut registrar = create_registrar();

    set_caller(accounts.alice);
    registrar.add_controller(accounts.bob).unwrap();

    let owner = select_account(owner_seed);
    let caller = select_account(caller_seed);
    let mut to = select_account(to_seed);
    if to == H160::zero() {
        to = accounts.eve;
    }

    let token_id = token_id_from_bytes(&token_bytes);

    set_caller(accounts.bob);
    registrar.register(token_id, owner).unwrap();

    set_caller(caller);
    let result = registrar.transfer_from(owner, to, token_id);

    if caller == owner {
        assert!(result.is_ok());
    } else {
        assert_eq!(result, Err(ERC721Error::NotOwnerOrApproved));
    }
}

#[fuzz(cases = 256)]
fn invariant_transfer_balance_accounting(
    context: Context,
    from_seed: u8,
    to_seed: u8,
    token_bytes: Vec<u8>,
) {
    context.apply();

    let accounts = default_accounts();
    let mut registrar = create_registrar();

    set_caller(accounts.alice);
    registrar.add_controller(accounts.bob).unwrap();

    let from = select_account(from_seed);
    let mut to = select_account(to_seed);
    if to == H160::zero() {
        to = accounts.eve;
    }

    let token_id = token_id_from_bytes(&token_bytes);

    set_caller(accounts.bob);
    registrar.register(token_id, from).unwrap();

    let from_before = registrar.balance_of(from);
    let to_before = registrar.balance_of(to);

    set_caller(from);
    registrar.transfer_from(from, to, token_id).unwrap();

    if from != to {
        assert_eq!(registrar.balance_of(from), from_before - U256::from(1));
        assert_eq!(registrar.balance_of(to), to_before + U256::from(1));
    }
}

#[fuzz(cases = 256)]
fn invariant_transfer_clears_approval(
    context: Context,
    owner_seed: u8,
    approved_seed: u8,
    to_seed: u8,
    token_bytes: Vec<u8>,
) {
    context.apply();

    let accounts = default_accounts();
    let mut registrar = create_registrar();

    set_caller(accounts.alice);
    registrar.add_controller(accounts.bob).unwrap();

    let owner = select_account(owner_seed);
    let approved = select_account(approved_seed);
    let mut to = select_account(to_seed);
    if to == H160::zero() {
        to = accounts.eve;
    }

    if owner == approved {
        return;
    }

    let token_id = token_id_from_bytes(&token_bytes);

    set_caller(accounts.bob);
    registrar.register(token_id, owner).unwrap();

    set_caller(owner);
    registrar.approve(approved, token_id).unwrap();
    registrar.transfer_from(owner, to, token_id).unwrap();

    assert_eq!(registrar.get_approved(token_id), None);
}

#[fuzz(cases = 256)]
fn invariant_no_transfer_to_zero_address(context: Context, owner_seed: u8, token_bytes: Vec<u8>) {
    context.apply();

    let accounts = default_accounts();
    let mut registrar = create_registrar();

    set_caller(accounts.alice);
    registrar.add_controller(accounts.bob).unwrap();

    let owner = select_account(owner_seed);
    let token_id = token_id_from_bytes(&token_bytes);

    set_caller(accounts.bob);
    registrar.register(token_id, owner).unwrap();

    set_caller(owner);
    let result = registrar.transfer_from(owner, H160::zero(), token_id);

    assert_eq!(result, Err(ERC721Error::TransferToZeroAddress));
}
