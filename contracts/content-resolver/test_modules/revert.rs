use crate::content_resolver::ContentResolver;
use crate::content_resolver::ContentResolverError;
use crate::dotns_content_resolver::*;
use dotns_registry::DotnsRegistryRef;
use dotns_registry::registry::BaseDotnsRegistry;
use dotns_reverse_resolver::DotnsReverseResolverRef;
use dotns_store::StoreRef;
use dotns_store_factory::StoreFactoryRef;
use ink::env::test;
use ink::prelude::vec;
use ink::primitives::{H160, H256};

fn accounts() -> test::DefaultAccounts {
    test::default_accounts()
}

fn set_caller(caller: H160) {
    test::set_caller(caller);
}

fn node_from_label(label: &str) -> H256 {
    use ink::env::hash::{HashOutput, Keccak256};
    let mut output = <Keccak256 as HashOutput>::Type::default();
    ink::env::hash_bytes::<Keccak256>(label.as_bytes(), &mut output);
    H256::from(output)
}

fn setup_registry() -> DotnsRegistryRef {
    let acc = accounts();
    let registry_code_hash = test::upload_code::<ink::env::DefaultEnvironment, DotnsRegistryRef>();
    let reverse_code_hash =
        test::upload_code::<ink::env::DefaultEnvironment, DotnsReverseResolverRef>();
    let store_factory_code_hash =
        test::upload_code::<ink::env::DefaultEnvironment, StoreFactoryRef>();
    let store_code_hash = test::upload_code::<ink::env::DefaultEnvironment, StoreRef>();

    let reverse_resolver = DotnsReverseResolverRef::new()
        .code_hash(reverse_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([1u8; 32]))
        .instantiate();

    let store_factory = StoreFactoryRef::new(store_code_hash)
        .code_hash(store_factory_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([2u8; 32]))
        .instantiate();

    let mut registry = DotnsRegistryRef::new(reverse_resolver, store_factory)
        .code_hash(registry_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([0u8; 32]))
        .instantiate();

    registry.update_registrar_controller(acc.alice).unwrap();

    registry
}

fn setup_resolver(registry: DotnsRegistryRef) -> DotnsContentResolver {
    DotnsContentResolver::new(registry)
}

#[ink::test]
fn test_non_owner_cannot_modify_records() {
    let acc = accounts();
    set_caller(acc.alice);

    let mut registry = setup_registry();
    let node = node_from_label("unauthorized");

    registry.set_owner(node, acc.alice, H160::zero()).unwrap();

    let mut resolver = setup_resolver(registry);

    set_caller(acc.bob);

    assert_eq!(
        resolver.set_contenthash(node, vec![0x01]),
        Err(ContentResolverError::NotAuthorised {
            node,
            caller: acc.bob
        })
    );
}

#[ink::test]
fn test_transfer_ownership_reverts_not_owner() {
    let acc = accounts();
    set_caller(acc.alice);

    let registry = setup_registry();
    let mut resolver = setup_resolver(registry);

    set_caller(acc.bob);

    assert_eq!(
        resolver.transfer_ownership(acc.charlie),
        Err(ContentResolverError::NotOwner)
    );
}

#[ink::test]
fn test_revoked_operator_cannot_modify() {
    let acc = accounts();
    set_caller(acc.alice);

    let mut registry = setup_registry();
    let node = node_from_label("revokedop");

    registry.set_owner(node, acc.alice, H160::zero()).unwrap();

    let mut resolver = setup_resolver(registry);

    resolver.set_approval_for_all(acc.bob, true);
    resolver.set_approval_for_all(acc.bob, false);

    set_caller(acc.bob);

    assert_eq!(
        resolver.set_contenthash(node, vec![0x01]),
        Err(ContentResolverError::NotAuthorised {
            node,
            caller: acc.bob
        })
    );
}
