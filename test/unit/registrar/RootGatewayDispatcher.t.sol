// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsPopController} from "../../../contracts/registrars/IDotnsPopController.sol";
import {
    RootGatewayDispatcher
} from "../../../contracts/registrars/RootGatewayDispatcher.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

// @title RootGatewayDispatcherTests
// @notice Unit coverage for the non-upgradeable shim that converts revive
//         Root-origin dispatches into `msg.sender`-based authorisation that
//         survives the controller proxy's `delegatecall` boundary (workaround
//         for polkadot-sdk PR #12051).
contract RootGatewayDispatcherTests is BaseDotns {
    // Selector of the typed `reserveLiteName(LiteRegistration)` overload,
    // computed explicitly so calldata construction does not collide with the
    // sibling `(bytes)` overload that the cross-chain payload entrypoint uses.
    bytes4 internal constant _RESERVE_LITE_TYPED_SELECTOR =
        bytes4(keccak256("reserveLiteName((string,address,bytes))"));

    RootGatewayDispatcher internal dispatcher;

    function setUp() public override {
        super.setUp();

        // Deploy the dispatcher bound to the already-deployed controller proxy
        // and install it as the authorised gateway.
        dispatcher = new RootGatewayDispatcher(address(dotnsPopController));
        vm.prank(owner);
        dotnsPopController.setGateway(address(dispatcher));

        // Default the System precompile to "not Root" so the dispatcher's
        // own precompile check is exercised by each test rather than the
        // base setup's blanket `_mockCallerIsRoot(true)`.
        _mockCallerIsRoot(false);
    }

    function test_dispatcher_target_is_immutable_and_points_to_controller() public view {
        assertEq(dispatcher.target(), address(dotnsPopController));
    }

    function test_dispatcher_reverts_when_caller_is_not_root() public {
        _grantPopFull(ed);
        bytes memory payload = abi.encodeWithSelector(
            _RESERVE_LITE_TYPED_SELECTOR,
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0x01)
            })
        );

        vm.expectRevert(RootGatewayDispatcher.NotRoot.selector);
        // `expectRevert` asserts the failure shape; the return tuple is
        // intentionally discarded.
        // solhint-disable-next-line no-unused-vars
        (bool ok,) = address(dispatcher).call(payload);
        ok;
    }

    function test_dispatcher_rejects_value_transfers() public {
        _mockCallerIsRoot(true);
        vm.deal(address(this), 1 ether);

        // Non-payable fallback rejects any non-zero `msg.value` before the
        // precompile check runs; the revert carries Solidity's default empty
        // payload, not `NotRoot`, so we just assert the call fails.
        (bool ok,) = address(dispatcher).call{value: 1 wei}("");
        assertFalse(ok);
    }

    function test_dispatcher_forwards_to_controller_when_root() public {
        _mockCallerIsRoot(true);
        _grantPopFull(ed);

        bytes memory payload = abi.encodeWithSelector(
            _RESERVE_LITE_TYPED_SELECTOR,
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0x01)
            })
        );

        (bool ok,) = address(dispatcher).call(payload);
        assertTrue(ok);

        bytes32 node = _nodeOf(LITE_LABEL_A);
        assertEq(dotnsRegistry.owner(node), ed);
    }

    function test_dispatcher_bubbles_controller_revert_data() public {
        _mockCallerIsRoot(true);
        // No PopFull tier granted: `_reserveLite -> priceWithCheck` will revert
        // inside the controller. The dispatcher must surface that revert
        // verbatim rather than masking it as `NotRoot`.
        bytes memory payload = abi.encodeWithSelector(
            _RESERVE_LITE_TYPED_SELECTOR,
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0x01)
            })
        );

        (bool ok, bytes memory ret) = address(dispatcher).call(payload);
        assertFalse(ok);
        // The controller's revert payload propagates: it is *not* the
        // dispatcher's `NotRoot()` selector.
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 32))
        }
        assertTrue(sel != RootGatewayDispatcher.NotRoot.selector);
    }

    function test_controller_authorises_call_from_dispatcher_address() public {
        // Dispatcher path: precompile reports non-Root (today's-SDK shape from
        // inside the proxy impl frame), but `msg.sender == gateway` carries
        // the call through the controller's gate.
        _grantPopFull(ed);

        vm.prank(address(dispatcher));
        dotnsPopController.reserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0x01)
            })
        );

        bytes32 node = _nodeOf(LITE_LABEL_A);
        assertEq(dotnsRegistry.owner(node), ed);
    }

    function test_controller_rejects_unknown_msg_sender_when_not_root() public {
        // Neither the precompile leg nor the gateway leg is satisfied.
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsPopController.NotGateway.selector, address(this))
        );
        dotnsPopController.reserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0x01)
            })
        );
    }

    function test_setGateway_reverts_for_non_owner() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(this)
            )
        );
        dotnsPopController.setGateway(address(0xBEEF));
    }

    function test_setGateway_reverts_on_zero_address() public {
        vm.expectRevert(IDotnsPopController.InvalidGateway.selector);
        vm.prank(owner);
        dotnsPopController.setGateway(address(0));
    }

    function test_setGateway_rotates_gateway() public {
        address newGateway = address(0xBEEF);

        vm.expectEmit(true, false, false, false, address(dotnsPopController));
        emit IDotnsPopController.GatewaySet(newGateway);
        vm.prank(owner);
        dotnsPopController.setGateway(newGateway);

        assertEq(dotnsPopController.gateway(), newGateway);

        // Old dispatcher no longer authorised.
        _grantPopFull(ed);
        vm.prank(address(dispatcher));
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsPopController.NotGateway.selector, address(dispatcher))
        );
        dotnsPopController.reserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0x01)
            })
        );
    }
}
