// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";
import {BaseDeployer} from "./BaseDeployer.s.sol";
import {DeploymentNetwork} from "./DeploymentNetwork.sol";

import {DotnsPopResolver} from "../../contracts/resolvers/DotnsPopResolver.sol";
import {DotnsPopController} from "../../contracts/registrars/DotnsPopController.sol";
import {RootGatewayDispatcher} from "../../contracts/registrars/RootGatewayDispatcher.sol";
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

        initDeployment(DeploymentNetwork.folder(block.chainid), vm.toString(block.chainid));

        address protocolRegistry = _readAddress("DotnsProtocolRegistry");

        _deployPopResolver(owner, protocolRegistry);
        address popController = _deployPopController(owner, protocolRegistry);
        _deployAndInstallGatewayDispatcher(owner, popController);

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
            abi.encodeCall(DotnsPopResolver.initialize, (IDotnsProtocolRegistry(protocolRegistry))),
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
                (IDotnsProtocolRegistry(protocolRegistry), DEFAULT_RESERVATION_DURATION)
            ),
            "DotnsPopController"
        );
    }

    /// @notice Deploys the {RootGatewayDispatcher} bound to the controller
    ///         proxy and installs its address on the controller via
    ///         `setGateway`.
    /// @dev Workaround for polkadot-sdk PR #12051: revive's
    ///      `ISystem.callerIsRoot()` does not survive the controller proxy's
    ///      `delegatecall` boundary on today's runtime. The dispatcher is a
    ///      non-upgradeable shim that is the direct callee of Root, performs
    ///      the precompile check in its own frame, and forwards the calldata
    ///      to the controller via a regular `CALL`. Wiring it via
    ///      `setGateway` rather than re-initialising the controller keeps the
    ///      change upgrade-safe for the existing Paseo deployment.
    /// @param owner Broadcasting account (also the controller owner; required
    ///        for the `setGateway` call).
    /// @param popController Address of the controller proxy from the previous
    ///        deploy step.
    /// @return dispatcher Address of the deployed `RootGatewayDispatcher`.
    function _deployAndInstallGatewayDispatcher(
        address owner,
        address popController
    )
        internal
        returns (address dispatcher)
    {
        vm.startBroadcast(owner);
        dispatcher = address(new RootGatewayDispatcher(popController));
        DotnsPopController(popController).setGateway(dispatcher);
        vm.stopBroadcast();

        vm.label(dispatcher, "RootGatewayDispatcher");
        logDeployment("RootGatewayDispatcher", dispatcher);
    }
}
