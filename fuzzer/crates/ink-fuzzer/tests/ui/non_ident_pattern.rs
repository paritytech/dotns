use ink_fuzzer::fuzz;

#[fuzz]
fn bad_pattern((_a, _b): (u32, u32)) {
    // should fail: parameter patterns must be idents
}
