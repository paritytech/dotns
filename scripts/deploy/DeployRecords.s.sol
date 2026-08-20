// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";
import {BaseDeployer} from "./BaseDeployer.s.sol";

import {DotnsResolver} from "../../contracts/resolvers/DotnsResolver.sol";
import {DotnsContentResolver} from "../../contracts/resolvers/DotnsContentResolver.sol";
import {PopRules} from "../../contracts/pop/PopRules.sol";
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
            abi.encodeCall(
                PopRules.initialize,
                (DotnsConstants.RENT_PRICE, IDotnsProtocolRegistry(protocolRegistry))
            ),
            "PopRules"
        );
    }
}
