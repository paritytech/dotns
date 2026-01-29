#![cfg(feature = "example-flipper")]

#[ink::contract]
pub mod flipper {
    use ink::prelude::string::String;

    #[ink(storage)]
    pub struct Flipper {
        value: bool,
    }

    impl Flipper {
        #[ink(constructor)]
        pub fn new(initial_value: bool) -> Self {
            Self {
                value: initial_value,
            }
        }

        #[ink(message)]
        pub fn get(&self) -> bool {
            self.value
        }

        #[ink(message)]
        pub fn set(&mut self, new_value: bool) {
            self.value = new_value;
        }

        #[ink(message)]
        pub fn flip(&mut self) {
            self.value = !self.value;
        }

        #[ink(message)]
        pub fn echo(&self, input: String) -> String {
            input
        }
    }
}
