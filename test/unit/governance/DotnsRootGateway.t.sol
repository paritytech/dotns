// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {DotnsRootGateway} from "../../../contracts/governance/DotnsRootGateway.sol";
import {IDotnsRootGateway} from "../../../contracts/governance/IDotnsRootGateway.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";
import {ISystem} from "../../../contracts/external/revive/ISystem.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";

/// @notice Minimal forwarding target that records what the gateway looked like as a caller.
contract TargetStub {
    address public lastCaller;
    uint256 public lastValue;
    bool public shouldRevert;

    error TargetReverted(uint256 marker);

    function ping(uint256 value) external {
        if (shouldRevert) revert TargetReverted(value);
        lastCaller = msg.sender;
        lastValue = value;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }
}

/// @title DotnsRootGatewayTest
/// @notice Covers the contract that carries the whole governance trust boundary.
/// @dev The registry is mocked rather than deployed: these tests are about the gateway's own
///      authorisation and forwarding, and a real registry would couple them to the full protocol
///      fixture. The gates that consume the gateway's identity are tested where they live.
contract DotnsRootGatewayTest is Test {
    DotnsRootGateway internal gateway;
    TargetStub internal target;

    address internal constant REGISTRY = address(uint160(0x9E6157A7));
    address internal constant OUTSIDER = address(uint160(0x0075106E));

    function setUp() public {
        gateway = new DotnsRootGateway(IDotnsProtocolRegistry(REGISTRY));
        target = new TargetStub();

        vm.label(address(gateway), "DotnsRootGateway");
        vm.label(address(target), "TargetStub");

        _mockCallerIsRoot(false);
        _mockRegistered(address(target), true);
        _mockRegistered(OUTSIDER, false);
    }

    function test_constructor_rejects_a_zero_registry() public {
        vm.expectRevert(IDotnsRootGateway.InvalidRegistry.selector);
        new DotnsRootGateway(IDotnsProtocolRegistry(address(0)));
    }

    /// @notice The gate is `callerIsRoot`, not the transaction origin.
    /// @dev This is the whole point of the contract. A signed caller is rejected even though it
    ///      can reach the function, and nothing about the transaction it sits in changes that.
    function test_execute_rejects_a_non_root_caller() public {
        _mockCallerIsRoot(false);
        vm.expectRevert(IDotnsRootGateway.NotRoot.selector);
        gateway.execute(_one(address(target)), _one(abi.encodeCall(TargetStub.ping, (1))));
    }

    function test_execute_forwards_and_the_target_sees_the_gateway() public {
        _mockCallerIsRoot(true);
        gateway.execute(_one(address(target)), _one(abi.encodeCall(TargetStub.ping, (42))));

        // The entire authorisation mechanism downstream: a regular CALL, so the callee observes
        // the gateway as `msg.sender` and can compare it against the registry key.
        assertEq(target.lastCaller(), address(gateway));
        assertEq(target.lastValue(), 42);
    }

    function test_execute_rejects_a_target_outside_the_protocol() public {
        _mockCallerIsRoot(true);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRootGateway.TargetNotProtocol.selector, OUTSIDER)
        );
        gateway.execute(_one(OUTSIDER), _one(abi.encodeCall(TargetStub.ping, (1))));
    }

    function test_execute_rejects_mismatched_lengths() public {
        _mockCallerIsRoot(true);
        address[] memory targets = new address[](2);
        targets[0] = address(target);
        targets[1] = address(target);
        vm.expectRevert(IDotnsRootGateway.LengthMismatch.selector);
        gateway.execute(targets, _one(abi.encodeCall(TargetStub.ping, (1))));
    }

    function test_execute_rejects_an_empty_batch() public {
        _mockCallerIsRoot(true);
        vm.expectRevert(IDotnsRootGateway.EmptyBatch.selector);
        gateway.execute(new address[](0), new bytes[](0));
    }

    /// @notice A failing call takes the whole batch with it, and the callee's error survives.
    /// @dev Governance reads the real revert reason rather than a generic gateway failure, and a
    ///      partially applied batch is never observable.
    function test_execute_bubbles_the_callee_revert_and_applies_nothing() public {
        _mockCallerIsRoot(true);
        target.setShouldRevert(true);

        address[] memory targets = new address[](2);
        targets[0] = address(target);
        targets[1] = address(target);
        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeCall(TargetStub.ping, (7));
        payloads[1] = abi.encodeCall(TargetStub.ping, (8));

        vm.expectRevert(abi.encodeWithSelector(TargetStub.TargetReverted.selector, uint256(7)));
        gateway.execute(targets, payloads);

        assertEq(target.lastCaller(), address(0));
    }

    function test_execute_applies_a_batch_in_order() public {
        _mockCallerIsRoot(true);
        address[] memory targets = new address[](2);
        targets[0] = address(target);
        targets[1] = address(target);
        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeCall(TargetStub.ping, (1));
        payloads[1] = abi.encodeCall(TargetStub.ping, (2));

        gateway.execute(targets, payloads);
        assertEq(target.lastValue(), 2);
    }

    function _mockCallerIsRoot(bool value) private {
        vm.mockCall(
            DotnsConstants.REVIVE_SYSTEM,
            abi.encodeWithSelector(ISystem.callerIsRoot.selector),
            abi.encode(value)
        );
    }

    function _mockRegistered(address addr, bool value) private {
        vm.mockCall(
            REGISTRY,
            abi.encodeWithSelector(IDotnsProtocolRegistry.isRegisteredAddress.selector, addr),
            abi.encode(value)
        );
    }

    function _one(address addr) private pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = addr;
    }

    function _one(bytes memory payload) private pure returns (bytes[] memory list) {
        list = new bytes[](1);
        list[0] = payload;
    }
}
