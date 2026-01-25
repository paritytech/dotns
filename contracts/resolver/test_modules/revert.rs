use crate::dotns_resolver::DotnsResolver;
use crate::resolver::{BaseDotnsResolver, ResolverError};
use dotns_registry::DotnsRegistryRef;
use dotns_registry::registry::BaseDotnsRegistry;
use dotns_reverse_resolver::DotnsReverseResolverRef;
use dotns_store::StoreRef;
use dotns_store_factory::StoreFactoryRef;
use ink::env::hash::{HashOutput, Keccak256};
use ink::env::test;
use ink::primitives::{H160, H256};

fn default_accounts() -> test::DefaultAccounts {
    test::default_accounts()
}

fn set_caller(caller: H160) {
    test::set_caller(caller);
}

struct TestEnv {
    resolver: DotnsResolver,
    registry: DotnsRegistryRef,
}

fn setup_test_env() -> TestEnv {
    let accounts = default_accounts();
    set_caller(accounts.alice);

    let registry_code_hash = test::upload_code::<ink::env::DefaultEnvironment, DotnsRegistryRef>();
    let reverse_resolver_code_hash =
        test::upload_code::<ink::env::DefaultEnvironment, DotnsReverseResolverRef>();
    let store_factory_code_hash =
        test::upload_code::<ink::env::DefaultEnvironment, StoreFactoryRef>();
    let store_code_hash = test::upload_code::<ink::env::DefaultEnvironment, StoreRef>();

    let reverse_resolver = DotnsReverseResolverRef::new()
        .code_hash(reverse_resolver_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([0u8; 32]))
        .instantiate();

    let store_factory = StoreFactoryRef::new(store_code_hash)
        .code_hash(store_factory_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([1u8; 32]))
        .instantiate();

    let registry = DotnsRegistryRef::new(reverse_resolver, store_factory)
        .code_hash(registry_code_hash)
        .endowment(0.into())
        .salt_bytes(Some([2u8; 32]))
        .instantiate();

    let resolver = DotnsResolver::new(registry.clone());

    TestEnv { resolver, registry }
}

fn labelhash(label: &str) -> H256 {
    let mut output = <Keccak256 as HashOutput>::Type::default();
    ink::env::hash_bytes::<Keccak256>(label.as_bytes(), &mut output);
    H256::from(output)
}

#[ink::test]
fn test_set_address_reverts_when_not_node_owner() {
    let accounts = default_accounts();
    let mut test_env = setup_test_env();

    set_caller(accounts.alice);
    test_env
        .registry
        .update_registrar_controller(accounts.alice)
        .unwrap();

    let node = labelhash("bobsnode");
    test_env
        .registry
        .set_owner(node, accounts.bob, accounts.alice)
        .unwrap();

    set_caller(accounts.charlie);

    let result = test_env.resolver.set_address(node, accounts.django);

    assert_eq!(
        result,
        Err(ResolverError::NotAuthorised {
            node,
            caller: accounts.charlie
        })
    );
}
