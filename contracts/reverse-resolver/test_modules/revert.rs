use crate::dotns_reverse_resolver::DotnsReverseResolver;
use crate::reverse_resolver::{BaseDotnsReverseResolver, ReverseResolverError};
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
fn test_update_registrar_controller_reverts_not_owner() {
    let mut resolver = setup_resolver();
    let acc = accounts();

    set_caller(acc.bob);
    let result = resolver.update_registrar_controller(acc.charlie);

    assert_eq!(result, Err(ReverseResolverError::NotOwner));
}

#[ink::test]
fn test_update_registrar_controller_reverts_invalid_registrar() {
    let mut resolver = setup_resolver();
    let acc = accounts();

    set_caller(acc.alice);
    let result = resolver.update_registrar_controller(H160::zero());

    assert_eq!(
        result,
        Err(ReverseResolverError::InvalidRegistrarController)
    );
}

#[ink::test]
fn test_set_reverse_name_reverts_not_registrar() {
    let mut resolver = setup_resolver();
    let acc = accounts();

    set_caller(acc.alice);
    resolver.update_registrar_controller(acc.bob).unwrap();

    set_caller(acc.charlie);
    let result = resolver.set_reverse_name(acc.django, String::from("test.dot"));

    assert_eq!(result, Err(ReverseResolverError::NotRegistrarController));
}

#[ink::test]
fn test_transfer_ownership_reverts_not_owner() {
    let mut resolver = setup_resolver();
    let acc = accounts();

    set_caller(acc.bob);
    let result = resolver.transfer_ownership(acc.charlie);

    assert_eq!(result, Err(ReverseResolverError::NotOwner));
}
