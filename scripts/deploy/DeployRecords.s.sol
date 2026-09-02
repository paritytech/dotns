// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";
import {BaseDeployer} from "./BaseDeployer.s.sol";

import {DotnsResolver} from "../../contracts/resolvers/DotnsResolver.sol";
import {DotnsContentResolver} from "../../contracts/resolvers/DotnsContentResolver.sol";
import {PopRules} from "../../contracts/pop/PopRules.sol";
import {DotnsFlatPricing} from "../../contracts/pop/DotnsFlatPricing.sol";
import {DotnsCostModelRegistry} from "../../contracts/pop/DotnsCostModelRegistry.sol";
import {IDotnsPricing} from "../../contracts/pop/IDotnsPricing.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";

/// @title DeployRecords
/// @notice Second stage. Deploys the resolver layer that holds per-name
///         records and the PoP-rules oracle that prices registrations. Reads
///         the protocol registry address populated by `DeployCore` so every
///         proxy binds to it on initialise.
/// @custom:security-contact admin@parity.io
contract DeployRecords is BaseDeployer {
    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        initDeployment(networkFolder(), vm.toString(block.chainid));

        address protocolRegistry = _readAddress("DotnsProtocolRegistry");

        _deployResolver(owner, protocolRegistry);
        _deployContentResolver(owner, protocolRegistry);
        _deployCostModelStack(owner);
        _deployPopRules(owner, protocolRegistry);

        saveDeployments();

        console.log("=== DeployRecords complete ===");
    }

    function _deployResolver(
        address owner,
        address protocolRegistry
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsResolver.sol:DotnsResolver",
            abi.encodeCall(DotnsResolver.initialize, (IDotnsProtocolRegistry(protocolRegistry))),
            "DotnsResolver"
        );
    }

    function _deployContentResolver(
        address owner,
        address protocolRegistry
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsContentResolver.sol:DotnsContentResolver",
            abi.encodeCall(
                DotnsContentResolver.initialize, (IDotnsProtocolRegistry(protocolRegistry))
            ),
            "DotnsContentResolver"
        );
    }

    /// @notice Deploys the flat launch model and the cost-model registry, then registers the model
    ///         so the registry serves it as the current version.
    /// @dev The `COST_MODEL` protocol-registry key points at the registry, not the model; the wire
    ///      stage sets that key. The flat model prices every admitted name at `BASE_DEPOSIT`;
    ///      `DotnsScarcityPricing` is held as a later candidate and is not registered here.
    function _deployCostModelStack(address owner) internal returns (address registry) {
        address model = _broadcastDeployCreate3(
            owner,
            "DotnsFlatPricing.sol:DotnsFlatPricing",
            abi.encode(DotnsConstants.BASE_DEPOSIT),
            "DotnsFlatPricing",
            // `deposit` is a constructor-set immutable in the runtime code.
            true
        );
        registry = _broadcastDeployCreate3(
            owner,
            "DotnsCostModelRegistry.sol:DotnsCostModelRegistry",
            abi.encode(owner),
            "DotnsCostModelRegistry"
        );

        // Idempotent for pipeline resume: re-running against an already-deployed
        // chain finds this version registered, so register only when it is absent
        // rather than reverting with AlreadyRegistered.
        IDotnsPricing pricing = IDotnsPricing(model);
        if (address(DotnsCostModelRegistry(registry).modelOf(pricing.version())) == address(0)) {
            vm.startBroadcast(owner);
            DotnsCostModelRegistry(registry).register(pricing);
            vm.stopBroadcast();
        }
    }

    function _deployPopRules(
        address owner,
        address protocolRegistry
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "PopRules.sol:PopRules",
            abi.encodeCall(PopRules.initialize, (IDotnsProtocolRegistry(protocolRegistry))),
            "PopRules"
        );
    }
}
