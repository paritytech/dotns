// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";

import {BaseDeployer} from "./BaseDeployer.s.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IDotnsPopController} from "../../contracts/registrars/IDotnsPopController.sol";

/// @title SetReservationDuration
/// @notice Sets the PoP controller's reservation duration to 30 days.
/// @dev The duration is runtime state, so an upgrade keeps the value the proxy already holds and a
///      new default in the source reaches only fresh deployments. This step writes it on the live
///      proxy. The new value applies to every queued reservation from the moment it lands,
///      existing ones included, because each entry's expiry is read against the current
///      duration. A run against a proxy that already holds the value broadcasts nothing.
/// @custom:security-contact admin@parity.io
contract SetReservationDuration is BaseDeployer {
    /// @notice Duration the step sets, in seconds.
    uint64 internal constant RESERVATION_DURATION = 30 days;

    /// @notice Manifest label the DotnsPopController proxy is recorded under.
    string internal constant POP_CONTROLLER_LABEL = "DotnsPopController";

    /// @notice Reads the manifest, resolves the controller, and sets the duration as `msg.sender`.
    /// @dev `msg.sender` must own the controller proxy, otherwise the run stops before
    ///      broadcasting.
    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        initDeployment(networkFolder(), vm.toString(block.chainid));

        _setReservationDuration(owner, _readAddress(POP_CONTROLLER_LABEL));

        console.log("=== SetReservationDuration complete ===");
    }

    /// @notice Sets `controller`'s reservation duration under `owner`, unless it already holds it.
    /// @param owner Account that owns the controller and broadcasts the write.
    /// @param controller DotnsPopController proxy address resolved from the manifest.
    function _setReservationDuration(address owner, address controller) internal {
        require(
            owner == OwnableUpgradeable(controller).owner(),
            "SetReservationDuration: broadcaster is not the controller owner"
        );

        IDotnsPopController popController = IDotnsPopController(controller);
        if (popController.reservationDuration() == RESERVATION_DURATION) {
            console.log("  reservation duration already set, skipping");
            return;
        }

        vm.broadcast(owner);
        popController.setReservationDuration(RESERVATION_DURATION);

        console.log("  reservation duration set to", uint256(RESERVATION_DURATION));
    }
}
