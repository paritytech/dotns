// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";
import {BaseDeployer} from "./BaseDeployer.s.sol";
import {DeploymentNetwork} from "./DeploymentNetwork.sol";

import {DotnsRegistrarController} from "../../contracts/registrars/DotnsRegistrarController.sol";
import {DotnsNameEscrow} from "../../contracts/escrow/DotnsNameEscrow.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";

/// @title DeployPolicy
/// @notice Third stage. Deploys the name escrow and the commit-reveal
///         controller, both of which bind to the protocol registry populated
///         by `DeployCore`.
/// @custom:security-contact admin@parity.io
contract DeployPolicy is BaseDeployer {
    uint64 public constant MIN_COMMITMENT_AGE = 6 seconds;
    uint64 public constant MAX_COMMITMENT_AGE = 1 days;
    uint256 public constant ESCROW_COOLDOWN = 15 minutes;

    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        initDeployment(DeploymentNetwork.folder(block.chainid), vm.toString(block.chainid));

        address protocolRegistry = _readAddress("DotnsProtocolRegistry");
        _deployNameEscrow(owner, protocolRegistry);
        _deployRegistrarController(owner, protocolRegistry);

        saveDeployments();

        console.log("=== DeployPolicy complete ===");
    }

    function _deployRegistrarController(
        address owner,
        address protocolRegistry
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsRegistrarController.sol:DotnsRegistrarController",
            abi.encodeCall(
                DotnsRegistrarController.initialize,
                (IDotnsProtocolRegistry(protocolRegistry), MIN_COMMITMENT_AGE, MAX_COMMITMENT_AGE)
            ),
            "DotnsRegistrarController"
        );
    }

    function _deployNameEscrow(
        address owner,
        address protocolRegistry
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsNameEscrow.sol:DotnsNameEscrow",
            abi.encodeCall(
                DotnsNameEscrow.initialize,
                (IDotnsProtocolRegistry(protocolRegistry), ESCROW_COOLDOWN)
            ),
            "DotnsNameEscrow"
        );
    }
}
