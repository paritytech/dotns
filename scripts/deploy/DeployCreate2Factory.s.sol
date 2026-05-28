// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";

import {Create2Factory} from "../../contracts/utils/Create2Factory.sol";

/// @title DeployCreate2Factory
/// @notice One-off bootstrap stage. Deploys the singleton `Create2Factory`
///         that every later stage routes its contract deploys through.
/// @dev Must be the very first transaction the deployer EOA broadcasts on a
///      fresh chain (nonce 0). The CREATE address of a contract depends only
///      on `(sender, nonce)`, so a same-EOA, same-nonce deploy lands on the
///      same factory address across every chain. `run.sh` enforces the nonce
///      check; this script only does the broadcast and logs the address so
///      the wrapper can read it back via the `RETURN`-style stdout match.
/// @custom:security-contact admin@parity.io
contract DeployCreate2Factory is Script {
    function run() external returns (address factory) {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        vm.startBroadcast(owner);
        Create2Factory deployed = new Create2Factory();
        vm.stopBroadcast();

        factory = address(deployed);
        vm.label(factory, "Create2Factory");
        console.log("Create2Factory deployed at", factory);
    }
}
