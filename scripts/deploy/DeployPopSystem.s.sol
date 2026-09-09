// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";
import {BaseDeployer} from "./BaseDeployer.s.sol";

import {DotnsPopResolver} from "../../contracts/resolvers/DotnsPopResolver.sol";
import {DotnsPopController} from "../../contracts/registrars/DotnsPopController.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";

/// @title DeployPopSystem
/// @notice Fourth stage. Deploys the PoP-specific proxies: the resolver that
///         holds chat keys and lite/full links, and the controller that drives
///         lite-person and full-person issuance. Both bind to the protocol
///         registry `DeployPolicy` deployed.
/// @custom:security-contact admin@parity.io
contract DeployPopSystem is BaseDeployer {
    /// @notice Default reservation duration for the PoP controller.
    /// @dev Mirrors `pallet_resources::UsernameReservationDuration`; the owner
    ///      rotates it post-deploy via `DotnsPopController.setReservationDuration`.
    uint64 public constant DEFAULT_RESERVATION_DURATION = 7 days;

    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        initDeployment(networkFolder(), vm.toString(block.chainid));

        address protocolRegistry = _readAddress("DotnsProtocolRegistry");

        _deployPopResolver(owner, protocolRegistry);
        address popController = _deployPopController(owner, protocolRegistry);
        _deployPopLens(owner, protocolRegistry);

        saveDeployments();

        console.log("=== DeployPopSystem complete ===");
    }

    function _deployPopResolver(
        address owner,
        address protocolRegistry
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsPopResolver.sol:DotnsPopResolver",
            abi.encodeCall(
                DotnsPopResolver.initialize, (owner, IDotnsProtocolRegistry(protocolRegistry))
            ),
            "DotnsPopResolver"
        );
    }

    function _deployPopController(
        address owner,
        address protocolRegistry
    )
        internal
        returns (address proxy)
    {
        proxy = _broadcastDeployUups(
            owner,
            "DotnsPopController.sol:DotnsPopController",
            abi.encodeCall(
                DotnsPopController.initialize,
                (owner, IDotnsProtocolRegistry(protocolRegistry), DEFAULT_RESERVATION_DURATION)
            ),
            "DotnsPopController"
        );
    }

    /// @notice Deploys the read-only PoP lens bound to the protocol registry and records it on
    ///         the manifest for the wire-up stage to register.
    /// @dev A plain CREATE3 deployment: the lens holds no state beyond the
    ///      registry it resolves siblings through, so it needs no proxy. Registry registration is
    ///      the wire-up stage's job.
    /// @param owner Broadcasting account.
    /// @param protocolRegistry Protocol registry the lens reads through.
    /// @return lens Address of the deployed lens.
    function _deployPopLens(
        address owner,
        address protocolRegistry
    )
        internal
        returns (address lens)
    {
        lens = _broadcastDeployCreate3(
            owner,
            "DotnsPopLens.sol:DotnsPopLens",
            abi.encode(protocolRegistry),
            "DotnsPopLens",
            // `_protocolRegistry` is a constructor-set immutable in the runtime code.
            true
        );
    }
}
