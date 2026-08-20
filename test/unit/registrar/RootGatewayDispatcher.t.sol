// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsPopController} from "../../../contracts/registrars/IDotnsPopController.sol";
import {RootGatewayDispatcher} from "../../../contracts/registrars/RootGatewayDispatcher.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";

/// @title RootGatewayDispatcherTests
/// @notice Unit coverage for the non-upgradeable shim that converts revive
///         Root-origin dispatches into the immediate-caller predicate the
///         controller authorises against.
contract RootGatewayDispatcherTests is BaseDotns {
    /// @notice Selector of the typed `reserveLiteName(LiteRegistration)`
    ///         overload, computed explicitly so calldata construction does not
    ///         collide with the sibling `(bytes)` overload that the cross-chain
    ///         payload entrypoint uses.
    bytes4 internal constant _RESERVE_LITE_TYPED_SELECTOR =
        bytes4(keccak256("reserveLiteName((string,address,bytes))"));

    /// @notice Dispatcher under test, deployed in `setUp` and bound to the
    ///         live controller proxy.
    RootGatewayDispatcher internal dispatcher;

    /// @notice Deploys the dispatcher bound to the already-deployed controller
    ///         proxy and rebinds the protocol registry's gateway slot so the
    ///         precompile path is exercised end-to-end. Defaults the System
    ///         precompile to "not Root" so each test opts in explicitly.
    function setUp() public override {
        super.setUp();

        dispatcher = new RootGatewayDispatcher(address(dotnsPopController));
        vm.prank(owner);
        protocolRegistry.set(DotnsConstants.POP_GATEWAY, address(dispatcher));

        _mockCallerIsRoot(false);
    }

    function test_dispatcher_target_is_immutable_and_points_to_controller() public view {
        assertEq(dispatcher.TARGET(), address(dotnsPopController));
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

        // Non-payable fallback rejects any non-zero value transfer before the
        // precompile check runs; the revert carries Solidity's default empty
        // payload, not NotRoot, so we just assert the call fails.
        (bool ok,) = address(dispatcher).call{value: 1 wei}("");
        assertFalse(ok);
    }

    function test_dispatcher_forwards_to_controller_when_root() public {
        _mockCallerIsRoot(true);
        _grantPopFull(ed);

        bytes memory payload = abi.encodeWithSelector(
            _RESERVE_LITE_TYPED_SELECTOR,
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A_DOTTED, user: ed, chatKey: _validChatKey(0x01)
            })
        );

        (bool ok,) = address(dispatcher).call(payload);
        assertTrue(ok);

        bytes32 node = _nodeOf(LITE_LABEL_A);
        assertEq(dotnsRegistry.owner(node), ed);
    }

    function test_dispatcher_bubbles_controller_revert_data() public {
        _mockCallerIsRoot(true);
        // The flat lite-label `LITE_LABEL_A` does not satisfy the gateway-facing
        // `stem.digits` shape, so the controller reverts with InvalidLiteLabel.
        // The dispatcher must surface that revert verbatim rather than masking it
        // as NotRoot.
        bytes memory payload = abi.encodeWithSelector(
            _RESERVE_LITE_TYPED_SELECTOR,
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0x01)
            })
        );

        (bool ok, bytes memory ret) = address(dispatcher).call(payload);
        assertFalse(ok);
        // The controller's revert payload propagates: it is not the
        // dispatcher's NotRoot selector.
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 32))
        }
        assertTrue(sel != RootGatewayDispatcher.NotRoot.selector);
    }

    function test_controller_authorises_call_from_dispatcher_address() public {
        // Dispatcher path: the precompile reports non-Root from inside the
        // controller's proxy implementation frame, but the dispatcher acting
        // as the immediate caller carries the call through the controller's
        // gateway check.
        _grantPopFull(ed);

        vm.prank(address(dispatcher));
        dotnsPopController.reserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A_DOTTED, user: ed, chatKey: _validChatKey(0x01)
            })
        );

        bytes32 node = _nodeOf(LITE_LABEL_A);
        assertEq(dotnsRegistry.owner(node), ed);
    }

    function test_controller_rejects_unknown_msg_sender_when_not_root() public {
        // Caller is neither the registered gateway nor a Root-origin
        // dispatch, so the gateway check rejects it.
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsPopController.NotGateway.selector, address(this))
        );
        dotnsPopController.reserveLiteName(
            IDotnsPopController.LiteRegistration({
                liteLabel: LITE_LABEL_A, user: ed, chatKey: _validChatKey(0x01)
            })
        );
    }

    function test_rotating_pop_gateway_key_revokes_old_dispatcher() public {
        address newGateway = address(0xBEEF);

        vm.prank(owner);
        protocolRegistry.set(DotnsConstants.POP_GATEWAY, newGateway);

        assertEq(protocolRegistry.get(DotnsConstants.POP_GATEWAY), newGateway);

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
