// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";
import {RegistrarControllerRoleHandler} from "./RegistrarControllerRoleHandler.t.sol";

/// @title DotnsRegistrarControllerRoleInvariantTest
/// @notice Invariants asserted over random sequences of `WHITELIST_OPERATOR_ROLE`
///         grants and revocations on the registrar controller.
contract DotnsRegistrarControllerRoleInvariantTest is BaseDotns {
    /// @notice Bounded random-action handler driving role transitions.
    RegistrarControllerRoleHandler public handler;

    /// @notice Wires the handler and constrains the fuzzer to its role-mutating
    ///         selectors.
    function setUp() public override {
        super.setUp();

        address[] memory actors = new address[](3);
        actors[0] = ed;
        actors[1] = leonardo;
        actors[2] = tiago;

        handler = new RegistrarControllerRoleHandler(dotnsRegistrarController, owner, actors);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.setWhitelistOperator.selector;
        selectors[1] = handler.grantWhitelistOperator.selector;
        selectors[2] = handler.revokeWhitelistOperator.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        excludeContract(address(dotnsRegistrarController));
    }

    /// @notice The on-chain `WHITELIST_OPERATOR_ROLE` membership for every
    ///         actor matches the handler's ghost record after any sequence of
    ///         grants, revokes, and setRole calls.
    function invariant_whitelist_operator_role_matches_ghost_state() public view {
        address[] memory actors = handler.actors();

        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];

            assertEq(
                dotnsRegistrarController.hasRole(DotnsConstants.WHITELIST_OPERATOR_ROLE, actor),
                handler.ghostWhitelistOperator(actor),
                "Whitelist operator role must match handler state"
            );
        }
    }
}
