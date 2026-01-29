use crate::dotns_reverse_resolver::DotnsReverseResolver;
use crate::reverse_resolver::{BaseDotnsReverseResolver, ReverseResolverError};
use ink::prelude::string::String;
use ink::prelude::vec::Vec;
use ink::primitives::H160;
use ink_fuzzer::{Context, fuzz};

fn default_accounts() -> ink::env::test::DefaultAccounts {
    ink::env::test::default_accounts()
}

fn set_caller(caller: H160) {
    ink::env::test::set_caller(caller);
}

fn create_resolver() -> DotnsReverseResolver {
    let accounts = default_accounts();
    set_caller(accounts.alice);
    DotnsReverseResolver::new()
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

fn bytes_to_name(bytes: &[u8]) -> String {
    if bytes.is_empty() {
        return String::from("default.dot");
    }

    let mut output: Vec<u8> = Vec::with_capacity(bytes.len());
    for byte in bytes {
        output.push(b'a' + (byte % 26));
    }
    output.extend_from_slice(b".dot");

    String::from_utf8(output).unwrap_or_else(|_| String::from("fallback.dot"))
}

#[fuzz(cases = 256)]
fn fuzz_only_owner_can_update_registrar_controller(
    context: Context,
    caller_seed: u8,
    registrar_seed: u8,
) {
    context.apply();

    let accounts = default_accounts();
    let mut resolver = create_resolver();

    let caller = select_account(caller_seed);
    let new_registrar = select_account(registrar_seed);

    set_caller(caller);
    let result = resolver.update_registrar_controller(new_registrar);

    if caller == accounts.alice {
        if new_registrar == H160::zero() {
            assert_eq!(
                result,
                Err(ReverseResolverError::InvalidRegistrarController)
            );
        } else {
            assert!(result.is_ok());
            assert_eq!(resolver.registrar(), new_registrar);
        }
    } else {
        assert_eq!(result, Err(ReverseResolverError::NotOwner));
    }
}

#[fuzz(cases = 256)]
fn fuzz_only_registrar_can_set_reverse_name(
    context: Context,
    caller_seed: u8,
    addr_seed: u8,
    name_bytes: Vec<u8>,
) {
    context.apply();

    let accounts = default_accounts();
    let mut resolver = create_resolver();

    set_caller(accounts.alice);
    resolver.update_registrar_controller(accounts.bob).unwrap();

    let caller = select_account(caller_seed);
    let addr = select_account(addr_seed);
    let name = bytes_to_name(&name_bytes);

    set_caller(caller);
    let result = resolver.set_reverse_name(addr, name.clone());

    if caller == accounts.bob {
        assert!(result.is_ok());
        assert_eq!(resolver.name_of(addr), name);
    } else {
        assert_eq!(result, Err(ReverseResolverError::NotRegistrarController));
    }
}

#[fuzz(cases = 256)]
fn fuzz_transfer_ownership_only_owner(context: Context, caller_seed: u8, new_owner_seed: u8) {
    context.apply();

    let accounts = default_accounts();
    let mut resolver = create_resolver();

    let caller = select_account(caller_seed);
    let new_owner = select_account(new_owner_seed);

    set_caller(caller);
    let result = resolver.transfer_ownership(new_owner);

    if caller == accounts.alice {
        assert!(result.is_ok());
        assert_eq!(resolver.owner(), new_owner);
    } else {
        assert_eq!(result, Err(ReverseResolverError::NotOwner));
        assert_eq!(resolver.owner(), accounts.alice);
    }
}

#[fuzz(cases = 256)]
fn fuzz_name_of_returns_empty_when_not_set(context: Context, addr_seed: u8) {
    context.apply();

    let resolver = create_resolver();
    let addr = select_account(addr_seed);

    assert_eq!(resolver.name_of(addr), String::from(""));
}
