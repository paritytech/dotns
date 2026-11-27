// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title Create3FactoryCode
/// @notice The canonical CREATE3 factory code, which every network runs at the factory address.
/// @dev Every dotNS address derives from the factory, so the deploy scripts accept only a
///      factory whose codehash is `RUNTIME_CODEHASH`. A fresh `Create3Factory` build cannot
///      serve as that reference: its runtime code ends in compiler metadata, which hashes the
///      sources and the compiler settings, so any edit to them, comments included, changes it.
///      Fresh chains deploy `INIT_CODE` so they run the same code as live ones. Unit tests check
///      that it deploys to `RUNTIME_CODEHASH` and that it is the `Create3Factory` build apart
///      from the metadata.
/// @dev Never regenerate these constants from a new build. The live factory keeps this code,
///      and any other codehash makes the deploy scripts reject it on every network. When a
///      compiler or settings change makes the tests fail, change the tests.
/// @custom:security-contact admin@parity.io
library Create3FactoryCode {
    /// @notice Codehash of the canonical factory's runtime code.
    bytes32 internal constant RUNTIME_CODEHASH =
        0x9112fa41c16dd54588ef4a0caed3a7b6d9c3100306465a91bd624d4e885ad69f;

    /// @notice Init code that deploys the canonical factory; its constructor takes no arguments.
    bytes internal constant INIT_CODE = hex"60808060405234601557610278908161001a8239f35b5f80fdfe608080604052600436101561001c575b5036"
        hex"1561001a575f80fd5b005b5f3560e01c9081630e787cce14610164575063cdcb760a1461003e575f61000f56"
        hex"5b60403660031901126101605760243560043567ffffffffffffffff82116101605736602383011215610160"
        hex"5781600401359067ffffffffffffffff82116101605760248301926024833692010111610160578115610151"
        hex"576100a13683856101d6565b906f67363d3d37363d34f03d5260086018f35f52806010805ff5918215610144"
        hex"575f80918460145261d694825260016034536017601e20946020825192019034905af1823b0215610144577f"
        hex"c30eb99366f0bd6014d7390b11a274cba6877d0c5a98f2a77606ec0b02b50f3a61011d602095604095369161"
        hex"01d6565b805190860120845190815234818701526001600160a01b03909316938493a3604051908152f35b63"
        hex"301164255f526004601cfd5b63f1e85bf960e01b5f5260045ffd5b5f80fd5b34610160576020366003190112"
        hex"61016057305f5260ff600b536004356020527f21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e499"
        hex"3a62319a497c1f6040526055600b2060145260405261d6945f5260016034536017601e206040516001600160"
        hex"a01b039091168152602090f35b92919267ffffffffffffffff821161022e5760405191601f8101601f199081"
        hex"16603f0116830167ffffffffffffffff81118482101761022e57604052829481845281830111610160578281"
        hex"602093845f960137010152565b634e487b7160e01b5f52604160045260245ffdfea2646970667358221220e0"
        hex"52e5a8bd957ed54ba8593d0419483a33f55121923901a967944cf859efd84364736f6c63430008220033";

    /// @notice Deploys the canonical factory with `CREATE` from the calling context.
    /// @return factory Address of the deployed factory.
    function deploy() internal returns (address factory) {
        bytes memory initCode = INIT_CODE;
        assembly ("memory-safe") {
            factory := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(factory != address(0), "Create3FactoryCode: deploy failed");
    }
}
