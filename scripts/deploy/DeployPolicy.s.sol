// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/Script.sol";
import {BaseDeployer} from "./BaseDeployer.s.sol";
import {DeploymentNetwork} from "./DeploymentNetwork.sol";

import {DotnsRegistrarController} from "../../contracts/registrars/DotnsRegistrarController.sol";
import {DotnsNameEscrow} from "../../contracts/escrow/DotnsNameEscrow.sol";
import {DotnsProtocolRegistry} from "../../contracts/registry/DotnsProtocolRegistry.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {IDotnsRegistrar} from "../../contracts/registrars/IDotnsRegistrar.sol";
import {IDotnsRegistry} from "../../contracts/registry/IDotnsRegistry.sol";
import {IDotnsReverseResolver} from "../../contracts/resolvers/IDotnsReverseResolver.sol";
import {IPopRules} from "../../contracts/pop/IPopRules.sol";
import {IStoreFactory} from "../../contracts/store/IStoreFactory.sol";

/// @title DeployPolicy
/// @notice Third stage. Deploys the commit-reveal controller and the
///         protocol registry. The controller reads every sibling it needs
///         from the addresses `DeployCore` and `DeployRecords` populated on
///         the manifest. The protocol registry is deployed here so the
///         PoP-system stage can wire to it without deploying its own.
/// @custom:security-contact admin@parity.io
contract DeployPolicy is BaseDeployer {
    uint64 public constant MIN_COMMITMENT_AGE = 6 seconds;
    uint64 public constant MAX_COMMITMENT_AGE = 1 days;
    uint256 public constant ESCROW_COOLDOWN = 7 days;

    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        initDeployment(DeploymentNetwork.folder(block.chainid), vm.toString(block.chainid));

        address protocolRegistry = _deployProtocolRegistry(owner);
        _deployNameEscrow(owner, protocolRegistry);
        _deployRegistrarController(owner);

        saveDeployments();

        console.log("=== DeployPolicy complete ===");
    }

    function _deployRegistrarController(address owner) internal returns (address proxy) {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsRegistrarController.sol:DotnsRegistrarController",
            abi.encodeCall(
                DotnsRegistrarController.initialize,
                (
                    IDotnsRegistrar(_readAddress("DotnsRegistrar")),
                    IDotnsRegistry(_readAddress("DotnsRegistry")),
                    IDotnsReverseResolver(_readAddress("DotnsReverseResolver")),
                    IPopRules(_readAddress("PopRules")),
                    IStoreFactory(_readAddress("StoreFactory")),
                    MIN_COMMITMENT_AGE,
                    MAX_COMMITMENT_AGE
                )
            ),
            "DotnsRegistrarController"
        );
    }

    function _deployProtocolRegistry(address owner) internal returns (address proxy) {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsProtocolRegistry.sol:DotnsProtocolRegistry",
            abi.encodeCall(DotnsProtocolRegistry.initialize, ()),
            "DotnsProtocolRegistry"
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
