// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/Script.sol";
import {BaseDeployer} from "./BaseDeployer.s.sol";
import {DeploymentNetwork} from "./DeploymentNetwork.sol";

import {DotnsResolver} from "../../contracts/resolvers/DotnsResolver.sol";
import {DotnsContentResolver} from "../../contracts/resolvers/DotnsContentResolver.sol";
import {PopRules} from "../../contracts/pop/PopRules.sol";
import {IDotnsRegistry} from "../../contracts/registry/IDotnsRegistry.sol";

/// @title DeployRecords
/// @notice Second stage. Deploys the resolver layer that holds per-name
///         records and the PoP-rules oracle that prices registrations. Reads
///         the forward registry address populated by `DeployCore` so the
///         record resolvers can bind to the same registry on initialise.
/// @custom:security-contact admin@parity.io
contract DeployRecords is BaseDeployer {
    uint256 public constant RENT_PRICE = 10e15 wei;

    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        initDeployment(DeploymentNetwork.folder(block.chainid), vm.toString(block.chainid));

        address registry = _readAddress("DotnsRegistry");

        _deployResolver(owner, registry);
        _deployContentResolver(owner, registry);
        _deployPopRules(owner);

        saveDeployments();

        console.log("=== DeployRecords complete ===");
    }

    function _deployResolver(address owner, address registry) internal returns (address proxy) {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsResolver.sol:DotnsResolver",
            abi.encodeCall(DotnsResolver.initialize, (IDotnsRegistry(registry))),
            "DotnsResolver"
        );
    }

    function _deployContentResolver(
        address owner,
        address registry
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsContentResolver.sol:DotnsContentResolver",
            abi.encodeCall(DotnsContentResolver.initialize, (IDotnsRegistry(registry))),
            "DotnsContentResolver"
        );
    }

    function _deployPopRules(address owner) internal returns (address proxy) {
        proxy = _broadcastDeployUups(
            owner,
            "PopRules.sol:PopRules",
            abi.encodeCall(PopRules.initialize, (RENT_PRICE)),
            "PopRules"
        );
    }
}
