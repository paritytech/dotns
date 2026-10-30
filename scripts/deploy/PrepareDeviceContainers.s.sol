// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";

import {BaseDeployer} from "./BaseDeployer.s.sol";
import {IDotnsPopController} from "../../contracts/registrars/IDotnsPopController.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {IDotnsRegistry} from "../../contracts/registry/IDotnsRegistry.sol";
import {LabelUtils} from "../../contracts/utils/LabelUtils.sol";

/// @title PrepareDeviceContainers
/// @notice Prepares the numeric device-name containers `00` to `99` on the PoP controller, one
///         transaction per container.
/// @dev The first device name issued in a container otherwise mints it inside the gateway's call,
///      which runs under a fixed weight limit and leaves that issuance little room. Preparing each
///      container from a signed transaction takes the cost out of issuance.
///      `prepareDeviceContainer` is permissionless: it mints a container that does not exist yet,
///      and records one the controller already owns.
///
///      One container per transaction keeps every broadcast bounded. Containers the controller has
///      already recorded are skipped, so an interrupted run is finished by running it again. A
///      container another account holds is skipped and logged, since the controller can never
///      prepare it and it would otherwise stop the run. `CONTAINER_FROM` and `CONTAINER_TO`
///      (inclusive, default 0 and 99) narrow the range for a local run.
/// @custom:security-contact admin@parity.io
contract PrepareDeviceContainers is BaseDeployer {
    /// @notice Storage slot of `DotnsPopController._deviceContainers` in this branch's layout.
    /// @dev The mapping has no getter. The fork test proves this slot against what
    ///      `prepareDeviceContainer` writes, so a layout change fails there first.
    uint256 internal constant DEVICE_CONTAINERS_SLOT = 10;

    /// @notice Highest container number.
    uint256 internal constant LAST_CONTAINER = 99;

    /// @notice Manifest label the DotnsPopController proxy is recorded under.
    string internal constant POP_CONTROLLER_LABEL = "DotnsPopController";

    /// @notice Manifest label the protocol registry is recorded under.
    string internal constant PROTOCOL_REGISTRY_LABEL = "DotnsProtocolRegistry";

    /// @notice Manifest label the forward registry is recorded under.
    string internal constant REGISTRY_LABEL = "DotnsRegistry";

    /// @notice Reads the manifest and prepares every container in the range as `msg.sender`.
    function run() external {
        address sender = msg.sender;
        vm.label(sender, "SENDER");

        initDeployment(networkFolder(), vm.toString(block.chainid));

        uint256 from = vm.envOr("CONTAINER_FROM", uint256(0));
        uint256 to = vm.envOr("CONTAINER_TO", LAST_CONTAINER);
        require(from <= to && to <= LAST_CONTAINER, "PrepareDeviceContainers: invalid range");

        _prepareContainers(
            sender,
            _readAddress(POP_CONTROLLER_LABEL),
            IDotnsRegistry(_readAddress(REGISTRY_LABEL)),
            IDotnsProtocolRegistry(_readAddress(PROTOCOL_REGISTRY_LABEL)).tldNode(),
            from,
            to
        );

        console.log("=== PrepareDeviceContainers complete ===");
    }

    /// @notice Prepares containers `from` to `to` on `controller`, skipping recorded ones and ones
    ///         another account holds.
    /// @param sender Account that broadcasts the calls.
    /// @param controller DotnsPopController proxy address resolved from the manifest.
    /// @param registry Forward registry, read for each container's owner.
    /// @param tldNode Node of the TLD the containers sit under.
    /// @param from First container number.
    /// @param to Last container number, inclusive.
    /// @return prepared Number of containers this run prepared.
    function _prepareContainers(
        address sender,
        address controller,
        IDotnsRegistry registry,
        bytes32 tldNode,
        uint256 from,
        uint256 to
    )
        internal
        returns (uint256 prepared)
    {
        (bool upgraded,) =
            controller.staticcall(abi.encodeWithSignature("MAX_QUEUE_STEPS_PER_CALL()"));
        require(upgraded, "PrepareDeviceContainers: run UpgradePopController first");

        for (uint256 number = from; number <= to; ++number) {
            string memory suffix = _suffix(number);
            if (_isRecorded(controller, tldNode, suffix)) continue;

            address holder = registry.owner(_containerNode(tldNode, suffix));
            if (holder != address(0) && holder != controller) {
                console.log("  skipping container held by another account", suffix, holder);
                continue;
            }

            vm.broadcast(sender);
            IDotnsPopController(controller).prepareDeviceContainer(suffix);

            require(
                _isRecorded(controller, tldNode, suffix),
                string.concat("PrepareDeviceContainers: container ", suffix, " not recorded")
            );
            ++prepared;
        }
        console.log("  containers prepared", prepared);
    }

    /// @notice Whether `controller` has recorded the container `suffix` as its own.
    /// @param controller DotnsPopController proxy.
    /// @param tldNode Node of the TLD the container sits under.
    /// @param suffix Two-digit container label.
    /// @return recorded True once the container is recorded.
    function _isRecorded(
        address controller,
        bytes32 tldNode,
        string memory suffix
    )
        internal
        view
        returns (bool recorded)
    {
        bytes32 slot =
            keccak256(abi.encode(_containerNode(tldNode, suffix), DEVICE_CONTAINERS_SLOT));
        recorded = vm.load(controller, slot) != bytes32(0);
    }

    /// @notice Node of the container `suffix` under the TLD.
    /// @param tldNode Node of the TLD.
    /// @param suffix Two-digit container label.
    /// @return node The container's node.
    function _containerNode(
        bytes32 tldNode,
        string memory suffix
    )
        internal
        pure
        returns (bytes32 node)
    {
        node = LabelUtils.namehashUnder(tldNode, LabelUtils.labelhashMemory(suffix));
    }

    /// @notice Two-digit label for container `number`, zero-padded.
    /// @param number Container number, 0 to 99.
    /// @return suffix The label, for example `07`.
    function _suffix(uint256 number) internal pure returns (string memory suffix) {
        suffix = string(
            abi.encodePacked(bytes1(uint8(48 + number / 10)), bytes1(uint8(48 + number % 10)))
        );
    }
}
