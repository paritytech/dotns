// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    ERC165Upgradeable
} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";

import {IDotnsPopResolver} from "./IDotnsPopResolver.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "../utils/DotnsConstants.sol";

/// @title DotnsPopResolver
/// @notice Per-node resolver holding records produced by the PoP username flow.
/// @dev Writes are gated on the protocol-registered `POP_CONTROLLER` rather
///      than on node ownership. PoP records are issued by the gateway as part
///      of identity issuance, not curated by the holder, so authority lives
///      with the controller and not the user.
/// @custom:security-contact admin@parity.io
contract DotnsPopResolver is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC165Upgradeable,
    IDotnsPopResolver
{
    /// @notice Protocol-level address registry used to resolve the authorised writer.
    IDotnsProtocolRegistry public protocolRegistry;

    /// @notice Stored chat-key bytes keyed by node.
    mapping(bytes32 node => bytes chatKey) private _chatKeys;

    /// @notice Stored device-name labelhash keyed by personhood-name node.
    /// @dev Forward direction: maps a personhood-name node to the labelhash of the device name it
    ///      is linked to.
    /// @custom:oz-renamed-from _liteLinks
    mapping(bytes32 personhoodNode => bytes32 deviceLabelhash) private _deviceLinks;

    /// @notice Reverse index mapping a device-name labelhash to the personhood-name node it is
    ///         linked to.
    /// @dev Written alongside `_deviceLinks` on every link so consumers that look up by device
    ///      name resolve the personhood name without scanning events. Zero when the device name
    ///      has never been linked.
    /// @custom:oz-renamed-from _fullClaims
    mapping(bytes32 deviceLabelhash => bytes32 personhoodNode) private _personhoodNodes;

    /// @dev Reserved storage space to allow for layout changes in the future.
    uint256[50] private __gap;

    /// @notice Restricts writes to the address registered as `POP_CONTROLLER`.
    modifier onlyPopController() {
        _onlyPopController();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialises the PoP resolver.
    /// @dev Called once through the UUPS proxy; `_disableInitializers` on the implementation
    ///      makes direct calls revert and any repeat call on the proxy reverts with
    ///      @custom:reverts InvalidInitialization. The registry pointer is the only storage this
    ///      setup needs because the authorised writer is resolved dynamically through
    ///      `POP_CONTROLLER`. Emits @custom:emits OwnershipTransferred when `msg.sender` is
    ///      recorded as the initial owner and @custom:emits Initialized once setup completes.
    /// @param initialOwner Address that owns the contract once initialised.
    /// @param registry Protocol-level address registry used for writer resolution.
    function initialize(
        address initialOwner,
        IDotnsProtocolRegistry registry
    )
        external
        initializer
    {
        __Ownable_init(initialOwner);
        __ERC165_init();
        protocolRegistry = registry;
    }

    /// @inheritdoc IDotnsPopResolver
    function setChatKey(
        bytes32 node,
        bytes calldata chatKeyBytes
    )
        external
        override
        onlyPopController
    {
        require(chatKeyBytes.length == 65, InvalidChatKeyLength(chatKeyBytes.length));
        _chatKeys[node] = chatKeyBytes;
        emit ChatKeyUpdated(node, chatKeyBytes);
    }

    /// @inheritdoc IDotnsPopResolver
    function setDeviceLink(
        bytes32 personhoodNode,
        bytes32 deviceLabelhash
    )
        external
        override
        onlyPopController
    {
        bytes32 oldDevice = _deviceLinks[personhoodNode];
        bytes32 oldPersonhood = _personhoodNodes[deviceLabelhash];
        if (oldDevice != bytes32(0) && oldDevice != deviceLabelhash) {
            delete _personhoodNodes[oldDevice];
        }
        if (oldPersonhood != bytes32(0) && oldPersonhood != personhoodNode) {
            delete _deviceLinks[oldPersonhood];
        }
        _deviceLinks[personhoodNode] = deviceLabelhash;
        _personhoodNodes[deviceLabelhash] = personhoodNode;
        emit DeviceLinkUpdated(personhoodNode, deviceLabelhash);
    }

    /// @inheritdoc IDotnsPopResolver
    function chatKey(bytes32 node) external view override returns (bytes memory) {
        return _chatKeys[node];
    }

    /// @inheritdoc IDotnsPopResolver
    function deviceLabelhashOf(bytes32 personhoodNode) external view override returns (bytes32) {
        return _deviceLinks[personhoodNode];
    }

    /// @inheritdoc IDotnsPopResolver
    function personhoodNodeOf(bytes32 deviceLabelhash) external view override returns (bytes32) {
        return _personhoodNodes[deviceLabelhash];
    }

    /// @notice Returns the release this network declares it runs, read live from the protocol
    ///         registry so every DotNS contract reports one synchronised value.
    /// @dev Mirror of `IDotnsProtocolRegistry.protocolVersion`, kept under the historical
    ///      `version()` selector for ABI compatibility. It reports the network's declaration,
    ///      not this contract's build; per-contract identity is the codehash declared on the
    ///      registry.
    /// @return versionString Declared release as bare semver, empty when never declared.
    function version() external view virtual returns (string memory versionString) {
        versionString = protocolRegistry.protocolVersion();
    }

    /// @inheritdoc ERC165Upgradeable
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return
            interfaceId == type(IDotnsPopResolver).interfaceId
                || super.supportsInterface(interfaceId);
    }

    /// @notice Internal check enforcing PoP-controller-only access.
    function _onlyPopController() internal view {
        address popController = protocolRegistry.get(DotnsConstants.POP_CONTROLLER);
        require(msg.sender == popController, NotPopController(msg.sender));
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
