// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BasePopFork} from "./BasePopFork.t.sol";
import {UpgradePopRulesHarness} from "./UpgradePopRules.t.sol";
import {UpgradePopControllerHarness} from "./UpgradePopController.t.sol";
import {UpgradeRegistrarControllerHarness} from "./UpgradeRegistrarController.t.sol";
import {RollbackProxy} from "../../scripts/deploy/RollbackProxy.s.sol";
import {IDotnsRegistry} from "../../contracts/registry/IDotnsRegistry.sol";

/// @title RollbackProxyHarness
/// @notice Runs the script's own internal under an explicit owner.
contract RollbackProxyHarness is RollbackProxy {
    /// @notice Rolls back the proxy recorded under `label`.
    function rollback(
        address owner,
        string memory label,
        address proxy,
        address controller
    )
        external
    {
        _rollback(owner, label, proxy, controller);
    }
}

/// @title RollbackProxyForkTest
/// @notice Pairs with `scripts/deploy/RollbackProxy.s.sol`. Upgrades the three proxies as the
///         campaign does, then proves each one goes back to the implementation it ran before, in
///         the order the script enforces, and that the rolled-back deployment still issues.
/// @dev Requires the local ETH-RPC adapter on `paseo_local`, or `PASEO_FORK_RPC`; see
///      `DEPLOYMENTS.md`. Run the suite with `bun run test:fork`.
/// @custom:security-contact admin@parity.io
contract RollbackProxyForkTest is BasePopFork {
    /// @notice Owner of every proxy.
    address internal owner;

    /// @notice The deployed proxies the campaign upgrades.
    address internal rules;
    address internal controller;
    address internal registrarController;

    /// @notice Their implementations before the campaign.
    address internal rulesBefore;
    address internal controllerBefore;
    address internal registrarControllerBefore;

    /// @notice Drives the script's rollback path.
    RollbackProxyHarness internal rollbacker;

    function setUp() public override {
        super.setUp();
        rules = _live("PopRules");
        controller = _live("DotnsPopController");
        registrarController = _live("DotnsRegistrarController");
        owner = _ownerOf(controller);
        rulesBefore = _implementationOf(rules);
        controllerBefore = _implementationOf(controller);
        registrarControllerBefore = _implementationOf(registrarController);
        rollbacker = new RollbackProxyHarness();

        new UpgradePopRulesHarness().upgrade(owner, rules);
        new UpgradePopControllerHarness().upgrade(owner, controller, rules);
        new UpgradeRegistrarControllerHarness().upgrade(owner, registrarController);
    }

    /// @notice The script's recorded addresses are the implementations live before the campaign.
    /// @dev Read from the fork before the upgrades in `setUp`, so a wrong constant in the script
    ///      fails here and never reaches a broadcast.
    function test_previous_implementations_match_the_chain() public {
        rollbacker.rollback(owner, "DotnsPopController", controller, controller);
        rollbacker.rollback(owner, "PopRules", rules, controller);
        rollbacker.rollback(owner, "DotnsRegistrarController", registrarController, controller);

        assertEq(_implementationOf(controller), controllerBefore, "controller back");
        assertEq(_implementationOf(rules), rulesBefore, "rules back");
        assertEq(
            _implementationOf(registrarController), registrarControllerBefore, "registrar back"
        );
    }

    /// @notice PopRules stays on the new implementation while the new controller is live.
    function test_rules_wait_for_the_controller() public {
        address rulesNow = _implementationOf(rules);

        vm.expectRevert(bytes("RollbackProxy: roll back DotnsPopController first"));
        rollbacker.rollback(owner, "PopRules", rules, controller);

        assertEq(_implementationOf(rules), rulesNow, "nothing moved");
    }

    /// @notice After a full rollback the deployment issues a linked pair, and a second rollback
    ///         run moves nothing.
    function test_rolled_back_deployment_issues_and_rerun_is_a_no_op() public {
        rollbacker.rollback(owner, "DotnsPopController", controller, controller);
        rollbacker.rollback(owner, "PopRules", rules, controller);

        rollbacker.rollback(owner, "DotnsPopController", controller, controller);
        rollbacker.rollback(owner, "PopRules", rules, controller);
        assertEq(_implementationOf(controller), controllerBefore, "controller unchanged");
        assertEq(_implementationOf(rules), rulesBefore, "rules unchanged");

        bytes32 personhoodNode = _issueLinkedPair(controller);
        assertEq(
            IDotnsRegistry(_live("DotnsRegistry")).owner(personhoodNode),
            popUser,
            "the previous pair issues"
        );
    }

    /// @notice A label outside the campaign is refused before anything is read or written.
    function test_unknown_label_is_refused() public {
        address registry = _live("DotnsRegistry");
        vm.expectRevert(
            bytes("RollbackProxy: ROLLBACK_PROXY is not a proxy this campaign upgrades")
        );
        rollbacker.rollback(owner, "DotnsRegistry", registry, controller);
    }
}
