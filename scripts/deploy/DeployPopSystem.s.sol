// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/Script.sol";
import {BaseDeployer} from "./BaseDeployer.s.sol";
import {DeploymentNetwork} from "./DeploymentNetwork.sol";

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

        initDeployment(DeploymentNetwork.folder(block.chainid), vm.toString(block.chainid));

        address protocolRegistry = _readAddress("DotnsProtocolRegistry");

        _deployPopResolver(owner, protocolRegistry);
        _deployPopController(owner, protocolRegistry);

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
}
