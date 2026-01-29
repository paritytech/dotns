use crate::dotns_reverse_resolver::DotnsReverseResolver;
use crate::reverse_resolver::BaseDotnsReverseResolver;
use ink::env::test;
use ink::prelude::string::String;
use ink::primitives::H160;

fn accounts() -> test::DefaultAccounts {
    test::default_accounts()
}

fn set_caller(caller: H160) {
    test::set_caller(caller);
}

fn setup_resolver() -> DotnsReverseResolver {
    let acc = accounts();
    set_caller(acc.alice);
    DotnsReverseResolver::new()
}

#[ink::test]
fn test_initialization() {
    let resolver = setup_resolver();
    let acc = accounts();

    assert_eq!(resolver.owner(), acc.alice);
    assert_eq!(resolver.registrar(), H160::zero());
    assert_eq!(resolver.version(), String::from("1.0.0"));
}

#[ink::test]
fn test_update_registrar_controller() {
    let mut resolver = setup_resolver();
    let acc = accounts();

    set_caller(acc.alice);
    resolver.update_registrar_controller(acc.bob).unwrap();

    assert_eq!(resolver.registrar(), acc.bob);
}

#[ink::test]
fn test_set_reverse_name() {
    let mut resolver = setup_resolver();
    let acc = accounts();

    set_caller(acc.alice);
    resolver.update_registrar_controller(acc.bob).unwrap();

    set_caller(acc.bob);
    resolver
        .set_reverse_name(acc.charlie, String::from("charlie.dot"))
        .unwrap();

    assert_eq!(resolver.name_of(acc.charlie), String::from("charlie.dot"));
}

#[ink::test]
fn test_name_of_returns_empty_when_not_set() {
    let resolver = setup_resolver();
    let acc = accounts();

    assert_eq!(resolver.name_of(acc.bob), String::from(""));
}

#[ink::test]
fn test_transfer_ownership() {
    let mut resolver = setup_resolver();
    let acc = accounts();

    set_caller(acc.alice);
    resolver.transfer_ownership(acc.bob).unwrap();

    assert_eq!(resolver.owner(), acc.bob);
}
