#![cfg_attr(not(feature = "std"), no_std, no_main)]
#![allow(unexpected_cfgs)]
#[cfg(all(feature = "example-flipper", feature = "example-erc20"))]
compile_error!("Enable only one of: `example-flipper` or `example-erc20`.");

#[cfg(feature = "example-flipper")]
pub mod flipper;

#[cfg(feature = "example-erc20")]
pub mod simple_erc20;

#[cfg(test)]
#[allow(dead_code)]
mod fuzz;
