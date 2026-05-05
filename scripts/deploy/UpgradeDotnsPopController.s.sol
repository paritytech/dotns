// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Options, Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UpgradeDotnsPopController is Script {
    string internal constant MANIFEST_PATH = "./deployments/paseo-assethub/420420417.json";

    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        address proxy = _readPopControllerAddress();
        require(proxy != address(0), "DotnsPopController not in deployment manifest");

        Options memory opts;
        opts.referenceContract = "DotnsPopControllerOld.sol:DotnsPopControllerOld";

        vm.startBroadcast(owner);
        Upgrades.upgradeProxy(proxy, "DotnsPopController.sol:DotnsPopController", "", opts);
        vm.stopBroadcast();

        console.log("=== UpgradeDotnsPopController complete ===");
        console.log("proxy", proxy);
    }

    function readPopControllerAddress() external view returns (address proxy) {
        proxy = _readPopControllerAddress();
    }

    function _readPopControllerAddress() internal view returns (address proxy) {
        require(vm.exists(MANIFEST_PATH), "deployment manifest missing");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory manifest = vm.readFile(MANIFEST_PATH);
        // Manifest is `{"contracts": {"X": "0x..."}}`; BaseDeployer assumes flat root keys.
        proxy = vm.parseJsonAddress(manifest, "$.contracts.DotnsPopController");
    }
}
