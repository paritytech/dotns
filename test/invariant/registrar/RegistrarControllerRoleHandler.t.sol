// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {DotnsRegistrarController} from "../../../contracts/registrars/DotnsRegistrarController.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";

/// @title RegistrarControllerRoleHandler
/// @notice Bounded random-action handler that mutates the registrar
///         controller's `WHITELIST_OPERATOR_ROLE` membership for a fixed
///         actor pool and mirrors the expected state in a ghost mapping.
contract RegistrarControllerRoleHandler is Test {
    /// @notice The registrar controller under test.
    DotnsRegistrarController public controller;
    /// @notice The account holding the default admin role on the controller.
    address public owner;
    /// @notice Actor pool whose role membership the handler toggles.
    address[] internal _actors;

    /// @notice Ghost mirror of `WHITELIST_OPERATOR_ROLE` membership the
    ///         handler expects the controller to hold per actor.
    mapping(address account => bool enabled) public ghostWhitelistOperator;

    /// @notice Initialises the handler with the controller, admin owner, and
    ///         the fixed actor pool.
    /// @param _controller The registrar controller.
    /// @param _owner The admin owner used to authorise role mutations.
    /// @param actorList Pool of accounts the handler cycles through.
    constructor(DotnsRegistrarController _controller, address _owner, address[] memory actorList) {
        controller = _controller;
        owner = _owner;
        _actors = actorList;
    }

    /// @notice Toggles the whitelist-operator role on a picked actor via
    ///         `setRole` and mirrors the result in the ghost mapping.
    function setWhitelistOperator(uint256 actorSeed, bool enabled) external {
        address account = _actors[actorSeed % _actors.length];

        vm.prank(owner);
        controller.setRole(DotnsConstants.WHITELIST_OPERATOR_ROLE, account, enabled);

        ghostWhitelistOperator[account] = enabled;
    }

    /// @notice Grants the whitelist-operator role on a picked actor via
    ///         `grantRole` and mirrors the result in the ghost mapping.
    function grantWhitelistOperator(uint256 actorSeed) external {
        address account = _actors[actorSeed % _actors.length];

        vm.prank(owner);
        controller.grantRole(DotnsConstants.WHITELIST_OPERATOR_ROLE, account);

        ghostWhitelistOperator[account] = true;
    }

    /// @notice Revokes the whitelist-operator role on a picked actor via
    ///         `revokeRole` and mirrors the result in the ghost mapping.
    function revokeWhitelistOperator(uint256 actorSeed) external {
        address account = _actors[actorSeed % _actors.length];

        vm.prank(owner);
        controller.revokeRole(DotnsConstants.WHITELIST_OPERATOR_ROLE, account);

        ghostWhitelistOperator[account] = false;
    }

    /// @notice Returns the actor pool the handler operates on.
    function actors() external view returns (address[] memory actorList) {
        actorList = _actors;
    }
}
