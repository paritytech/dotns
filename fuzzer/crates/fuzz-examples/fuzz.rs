#[cfg(test)]
#[allow(dead_code)]
use ink::env::test;
use ink_fuzzer::{fuzz, Context};

type Environment = ink::env::DefaultEnvironment;
type Address = ink::H160;

fn default_accounts() -> test::DefaultAccounts {
    test::default_accounts()
}

fn set_environment_caller(caller: Address) {
    test::set_caller(caller);
}

fn set_environment_block_timestamp(timestamp: u64) {
    test::set_block_timestamp::<Environment>(timestamp);
}

fn pick_account_from_seed(seed: u8, accounts: &test::DefaultAccounts) -> Address {
    match seed % 6 {
        0 => accounts.alice,
        1 => accounts.bob,
        2 => accounts.charlie,
        3 => accounts.django,
        4 => accounts.eve,
        _ => accounts.frank,
    }
}

#[cfg(feature = "example-flipper")]
mod flipper_fuzz {
    use super::*;
    use crate::flipper::flipper::Flipper;

    fn make_flipper(initial_value: bool) -> Flipper {
        Flipper::new(initial_value)
    }

    #[fuzz(cases = 512)]
    fn fuzz_flipper_never_panics_on_repeated_flips(
        context: Context,
        initial_value: bool,
        flip_seed: u16,
    ) {
        context.apply();

        let mut contract = make_flipper(initial_value);

        let flip_count: u16 = flip_seed % 1024;
        for _ in 0..flip_count {
            contract.flip();
        }

        let expected_value = if (flip_count % 2) == 0 {
            initial_value
        } else {
            !initial_value
        };

        assert_eq!(contract.get(), expected_value);
    }
}

#[cfg(feature = "example-erc20")]
mod erc20_fuzz {
    use super::*;
    use crate::simple_erc20::simple_erc20::SimpleErc20;
    use ink::prelude::string::String;

    fn make_token() -> SimpleErc20 {
        let accounts = default_accounts();
        set_environment_caller(accounts.alice);
        SimpleErc20::new(String::from("Token"), String::from("TKN"), 18)
    }

    #[fuzz(cases = 512)]
    fn fuzz_token_transfer_preserves_total_supply(
        context: Context,
        sender_seed: u8,
        recipient_seed: u8,
        minted_amount_seed: u128,
        transfer_amount_seed: u128,
    ) {
        context.apply();

        let accounts = default_accounts();
        let mut token = make_token();

        let sender = pick_account_from_seed(sender_seed, &accounts);
        let recipient = pick_account_from_seed(recipient_seed, &accounts);

        if sender == recipient {
            return;
        }

        // Mint to `sender` as owner (alice).
        set_environment_caller(accounts.alice);
        let minted_amount: u128 = (minted_amount_seed % 1_000_000u128) + 1;
        assert!(token.mint(sender, minted_amount));

        let total_supply_before = token.total_supply();
        let sender_balance_before = token.balance_of(sender);
        let recipient_balance_before = token.balance_of(recipient);

        // Transfer as `sender`.
        set_environment_caller(sender);
        let transfer_amount: u128 = transfer_amount_seed % (sender_balance_before + 1);
        assert!(token.transfer(recipient, transfer_amount));

        let total_supply_after = token.total_supply();
        let sender_balance_after = token.balance_of(sender);
        let recipient_balance_after = token.balance_of(recipient);

        assert_eq!(total_supply_after, total_supply_before);
        assert_eq!(
            sender_balance_after,
            sender_balance_before - transfer_amount
        );
        assert_eq!(
            recipient_balance_after,
            recipient_balance_before + transfer_amount
        );
    }

    #[fuzz(cases = 512)]
    fn fuzz_token_transfer_fails_on_insufficient_balance(
        context: Context,
        sender_seed: u8,
        recipient_seed: u8,
        small_balance_seed: u16,
        large_transfer_seed: u16,
    ) {
        context.apply();

        let accounts = default_accounts();
        let mut token = make_token();

        let sender = pick_account_from_seed(sender_seed, &accounts);
        let recipient = pick_account_from_seed(recipient_seed, &accounts);

        if sender == recipient {
            return;
        }

        set_environment_caller(accounts.alice);
        let small_balance: u128 = (small_balance_seed as u128 % 1000) + 1;
        assert!(token.mint(sender, small_balance));

        set_environment_caller(sender);
        let transfer_amount: u128 = small_balance + (large_transfer_seed as u128 % 1000) + 1;

        assert!(!token.transfer(recipient, transfer_amount));
    }

    #[fuzz(cases = 256)]
    fn fuzz_token_mint_is_owner_only(context: Context, caller_seed: u8, amount_seed: u128) {
        context.apply();

        let accounts = default_accounts();
        let mut token = make_token();

        let caller = pick_account_from_seed(caller_seed, &accounts);
        let recipient = accounts.bob;
        let mint_amount: u128 = (amount_seed % 1_000_000u128) + 1;

        set_environment_caller(caller);
        let mint_succeeded = token.mint(recipient, mint_amount);

        if caller == accounts.alice {
            assert!(mint_succeeded);
        } else {
            assert!(!mint_succeeded);
        }
    }

    #[fuzz(cases = 256)]
    fn fuzz_time_dependent_example(context: Context, base_time_seed: u64, delta_seed: u64) {
        context.apply();

        let start_time: u64 = 1_000u64 + (base_time_seed % 10_000u64);
        let offset: u64 = delta_seed % 1_000_000u64;

        set_environment_block_timestamp(start_time);
        let first_timestamp = ink::env::block_timestamp::<Environment>();

        set_environment_block_timestamp(start_time + offset);
        let second_timestamp = ink::env::block_timestamp::<Environment>();

        assert!(second_timestamp >= first_timestamp);
    }
}
