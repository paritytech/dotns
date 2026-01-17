use ink_fuzzer::fuzz;

#[fuzz]
async fn bad_async(_x: u32) {
    // should fail: async not supported
}
