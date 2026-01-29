use proc_macro::TokenStream;
use quote::{format_ident, quote};
use syn::{parse::Parse, parse_macro_input, spanned::Spanned, ItemFn};

struct FuzzArguments {
    cases: Option<usize>,
}

impl Default for FuzzArguments {
    fn default() -> Self {
        Self { cases: None }
    }
}

impl Parse for FuzzArguments {
    fn parse(input: syn::parse::ParseStream) -> syn::Result<Self> {
        let mut parsed_arguments = FuzzArguments::default();
        if input.is_empty() {
            return Ok(parsed_arguments);
        }

        let meta_item: syn::Meta = input.parse()?;
        match meta_item {
            syn::Meta::List(meta_list) => {
                let nested_items = meta_list.parse_args_with(
                    syn::punctuated::Punctuated::<syn::Meta, syn::Token![,]>::parse_terminated,
                )?;
                for nested_meta_item in nested_items {
                    parse_single_meta_item(&mut parsed_arguments, nested_meta_item)?;
                }
                Ok(parsed_arguments)
            }
            syn::Meta::NameValue(name_value_meta) => {
                parse_name_value_item(&mut parsed_arguments, name_value_meta)?;
                Ok(parsed_arguments)
            }
            syn::Meta::Path(_) => Ok(parsed_arguments),
        }
    }
}

fn parse_single_meta_item(
    parsed_arguments: &mut FuzzArguments,
    meta_item: syn::Meta,
) -> syn::Result<()> {
    match meta_item {
        syn::Meta::NameValue(name_value_meta) => {
            parse_name_value_item(parsed_arguments, name_value_meta)
        }
        _ => Ok(()),
    }
}

fn parse_name_value_item(
    parsed_arguments: &mut FuzzArguments,
    name_value_meta: syn::MetaNameValue,
) -> syn::Result<()> {
    if name_value_meta.path.is_ident("cases") {
        let value_expression = name_value_meta.value;

        let parsed_cases: usize = match value_expression {
            syn::Expr::Lit(literal_expression) => match literal_expression.lit {
                syn::Lit::Int(integer_literal) => integer_literal.base10_parse::<usize>()?,
                other_literal => {
                    return Err(syn::Error::new(
                        other_literal.span(),
                        "cases must be an integer literal",
                    ))
                }
            },
            _ => {
                return Err(syn::Error::new(
                    value_expression.span(),
                    "cases must be an integer literal",
                ))
            }
        };

        parsed_arguments.cases = Some(parsed_cases);
    }

    Ok(())
}

#[proc_macro_attribute]
pub fn fuzz(attribute_tokens: TokenStream, item_tokens: TokenStream) -> TokenStream {
    let parsed_arguments = parse_macro_input!(attribute_tokens as FuzzArguments);
    let mut user_function = parse_macro_input!(item_tokens as ItemFn);

    if user_function.sig.asyncness.is_some() {
        return syn::Error::new(
            user_function.sig.asyncness.span(),
            "#[ink_fuzzer::fuzz] does not support async functions",
        )
        .to_compile_error()
        .into();
    }

    let original_function_identifier = user_function.sig.ident.clone();
    let internal_function_identifier =
        format_ident!("__ink_fuzzer_internal_{}", original_function_identifier);

    // A stable, user-callable, no-arg entrypoint for running the property test wrapper.
    let runner_function_identifier = format_ident!("run_{}", original_function_identifier);

    // Collect identifier patterns and types so we can:
    // 1. Generate strategies for each argument type: any::<Type>()
    // 2. Call the internal helper as: __ink_fuzzer_internal_name(arg1, arg2, ...)
    let mut function_argument_identifiers: Vec<syn::Ident> = Vec::new();
    let mut function_argument_types: Vec<syn::Type> = Vec::new();

    for function_input in user_function.sig.inputs.iter() {
        match function_input {
            syn::FnArg::Typed(typed_argument) => match &*typed_argument.pat {
                syn::Pat::Ident(identifier_pattern) => {
                    function_argument_identifiers.push(identifier_pattern.ident.clone());
                    function_argument_types.push((*typed_argument.ty).clone());
                }
                other_pattern => {
                    return syn::Error::new(
                        other_pattern.span(),
                        "fuzz parameters must be simple identifiers (e.g. `value: u32`)",
                    )
                    .to_compile_error()
                    .into();
                }
            },
            syn::FnArg::Receiver(_) => {
                return syn::Error::new(
                    function_input.span(),
                    "methods with `self` are not supported; use a free function in tests/",
                )
                .to_compile_error()
                .into();
            }
        }
    }

    // Rename the user function to an internal helper symbol.
    user_function.sig.ident = internal_function_identifier.clone();

    let configured_cases: u32 = parsed_arguments.cases.unwrap_or(256) as u32;

    // Build the strategy tuple for proptest. Each argument type gets an any::<T>() strategy.
    // For zero arguments, we use Just(()) as a placeholder strategy.
    let strategy_tuple = if function_argument_types.is_empty() {
        quote! { ::ink_fuzzer::proptest::strategy::Just(()) }
    } else {
        let strategies = function_argument_types.iter().map(|ty| {
            quote! { ::ink_fuzzer::proptest::arbitrary::any::<#ty>() }
        });
        quote! { (#(#strategies),*) }
    };

    // Build the destructure pattern for extracting generated values from the strategy.
    // Single arguments don't need tuple wrapping.
    let destructure_pattern = if function_argument_identifiers.is_empty() {
        quote! { _ }
    } else if function_argument_identifiers.len() == 1 {
        let id = &function_argument_identifiers[0];
        quote! { #id }
    } else {
        quote! { (#(#function_argument_identifiers),*) }
    };

    let expanded_tokens = quote! {
        // Internal helper containing the original user code.
        #user_function

        // Property test wrapper. We manually use TestRunner instead of #[property_test]
        // so that all proptest paths go through ::ink_fuzzer::proptest::, allowing users
        // to only depend on ink-fuzzer without an explicit proptest dependency.
        #[test]
        fn #original_function_identifier() {
            use ::ink_fuzzer::proptest::strategy::Strategy;
            use ::ink_fuzzer::proptest::test_runner::{TestError, TestRunner, Config};

            let config = Config {
                cases: #configured_cases,
                failure_persistence: ::core::option::Option::None,
                max_shrink_iters: 4,
                ..Config::default()
            };

            let mut runner = TestRunner::new(config);

            let strategy = #strategy_tuple;

            runner.run(&strategy, |#destructure_pattern| {
                // Initialize ink!'s off-chain env per case and call the internal helper.
                ::ink::env::test::run_test::<::ink::env::DefaultEnvironment, _>(
                    |_accounts| -> ::core::result::Result<(), ::ink::env::Error> {
                        #internal_function_identifier(#(#function_argument_identifiers),*);
                        Ok(())
                    }
                ).expect("ink_fuzzer: failed to initialize ink off-chain test environment");
                Ok(())
            }).expect(&format!("Test failed: {}", stringify!(#original_function_identifier)));
        }

        // No-arg entrypoint for consumers that want to trigger the fuzz campaign explicitly
        // from other tests without needing to know the wrapper signature.
        fn #runner_function_identifier() {
            #original_function_identifier();
        }
    };

    expanded_tokens.into()
}