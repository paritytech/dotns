#![cfg_attr(not(feature = "std"), no_std, no_main)]
use hex_literal::hex;
use ink::primitives::H256;

pub mod macros;
pub mod store;

/// Key prefix for DotNS-written Store entries ("dotns.registered").
pub const DOTNS_REGISTERED_KEY: H256 = H256(*b"dotns.registered\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0");

/// Namehash of the .dot TLD.
pub const DOT_NODE: H256 = H256(hex!(
    "3fce7d1364a893e213bc4212792b517ffc88f5b13b86c8ef9c8d390c3a1370ce"
));
