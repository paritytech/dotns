// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/Script.sol";
import {BaseDeployer} from "./BaseDeployer.s.sol";

import {PopRules} from "../../contracts/pop/PopRules.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";

import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";

/// @title UpgradePopRules
/// @notice Stand-alone upgrade script for the PopRules proxy. Ships separately
///         from {UpgradePopSystem} so each script's OpenZeppelin upgrade-safety
///         validations run in their own forge-script process. Validating every
///         live proxy in one simulation crosses the memory-expansion-gas budget.
/// @custom:security-contact admin@parity.io
contract UpgradePopRules is BaseDeployer {
    address public constant POP_RULES_PROXY = 0x4e8920B1E69d0cEA9b23CBFC87A17Ee6fE02d2d3;
    address public constant PROTOCOL_REGISTRY_PROXY = 0xF8531342444fAC0A75719130eECcf45314584EFe;

    string public constant POP_RULES_VERSION = "1.2.0";

    string internal constant _POP_RULES_NEW = "PopRules.sol:PopRules";
    string internal constant _POP_RULES_OLD = "PopRulesOld.sol:PopRulesOld";

    /// @notice Standard run entrypoint; executed live against the configured chain.
    /// @dev Broadcasts as `msg.sender`. The caller must own the PopRules proxy.
    function run() external {
        console.log("=== PopRules Upgrade ===");
        console.log("Chain ID:", block.chainid);

        Options memory opts;
        opts.referenceContract = _POP_RULES_OLD;

        vm.startBroadcast(msg.sender);
        Upgrades.upgradeProxy(POP_RULES_PROXY, _POP_RULES_NEW, "", opts, msg.sender);
        PopRules(POP_RULES_PROXY)
            .updateProtocolRegistry(IDotnsProtocolRegistry(PROTOCOL_REGISTRY_PROXY));
        vm.stopBroadcast();

        verifyUpgrade();
    }

    /// @notice Fork-test entry point that mirrors `run()` without an active
    ///         broadcast. `vm.prank` authorizes the owner-only wiring call;
    ///         `vm.prank` is forbidden under `vm.startBroadcast`, which is why
    ///         `run()` inlines these steps rather than delegating here.
    /// @param caller Owner of the PopRules proxy.
    function upgrade(address caller) public {
        Options memory opts;
        opts.referenceContract = _POP_RULES_OLD;
        Upgrades.upgradeProxy(POP_RULES_PROXY, _POP_RULES_NEW, "", opts, caller);

        vm.prank(caller);
        PopRules(POP_RULES_PROXY)
            .updateProtocolRegistry(IDotnsProtocolRegistry(PROTOCOL_REGISTRY_PROXY));
    }

    /// @notice Post-upgrade verification; shared by `run` and fork tests so a single
    ///         assertion surface covers both live deploys and pre-merge simulation.
    function verifyUpgrade() public view {
        require(
            keccak256(bytes(PopRules(POP_RULES_PROXY).version()))
                == keccak256(bytes(POP_RULES_VERSION)),
            "PopRules: wrong version after upgrade"
        );
        require(
            address(PopRules(POP_RULES_PROXY).protocolRegistry()) == PROTOCOL_REGISTRY_PROXY,
            "PopRules: protocol registry mis-wired"
        );

        console.log("=== PopRules upgrade verified ===");
    }
}
