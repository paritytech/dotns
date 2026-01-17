/// Ensures a condition is met, otherwise returns an error.
///
/// # Usage
///
/// ```ignore
/// use crate::utils::require;
///
/// fn transfer(&mut self, to: AccountId, amount: u128) -> Result<(), MyError> {
///     require!(amount > 0, MyError::InvalidAmount);
///     require!(self.balance >= amount, MyError::InsufficientBalance);
///     // ... rest of implementation
///     Ok(())
/// }
/// ```
///
/// # Arguments
///
/// * `$cond` - Boolean expression to evaluate.
/// * `$err` - Error to return if condition is false.
#[macro_export]
macro_rules! require {
    ($cond:expr, $err:expr) => {
        if !$cond {
            return Err($err);
        }
    };
}
