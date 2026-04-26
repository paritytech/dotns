// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

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
/// @dev Authorised writer is the `POP_CONTROLLER` address on the protocol registry;
///      rotating the PoP controller requires no resolver upgrade.
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

    /// @notice Stored lite-person labelhash keyed by full-person node.
    /// @dev Forward direction (full => lite): maps a full-person node to the
    ///      labelhash of the lite username it was claimed from.
    mapping(bytes32 fullNode => bytes32 liteLabelhash) private _liteLinks;

    /// @notice Reverse index mapping a lite labelhash to the full-person node
    ///         it was promoted to.
    /// @dev Written alongside `_liteLinks` on every claim so consumers that
    ///      look up by lite username resolve the full name without scanning
    ///      events. Zero when the lite label has never been linked to a full
    ///      claim.
    mapping(bytes32 liteLabelhash => bytes32 fullNode) private _fullClaims;

    /// @dev Reserved storage space to allow for layout changes in the future.
    uint256[49] private __gap;

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
    /// @dev Called once through the UUPS proxy; `_disableInitializers` on the
    ///      implementation makes direct calls revert. The registry pointer is
    ///      the only storage this setup needs because the authorised writer
    ///      is resolved dynamically through `POP_CONTROLLER`.
    /// @param registry Protocol-level address registry used for writer resolution.
    function initialize(IDotnsProtocolRegistry registry) external initializer {
        __Ownable_init(msg.sender);
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
        // Chat keys are uncompressed secp256k1 public keys: 1 prefix byte plus
        // the 32-byte X and 32-byte Y affine coordinates. Reject any other
        // length so downstream consumers can rely on the stored shape.
        require(chatKeyBytes.length == 65, InvalidChatKeyLength(chatKeyBytes.length));
        _chatKeys[node] = chatKeyBytes;
        emit ChatKeyUpdated(node, chatKeyBytes);
    }

    /// @inheritdoc IDotnsPopResolver
    function setLiteLink(
        bytes32 fullNode,
        bytes32 liteLabelhash
    )
        external
        override
        onlyPopController
    {
        // Null any stale inverse entries before re-writing so the forward and
        // reverse indices stay in lockstep after every call. Without this,
        // re-linking the same `fullNode` to a new `liteLabelhash` (or vice
        // versa) would leave the previous inverse pointing at a node it no
        // longer claims, breaking the `fullClaim(liteLink(node)) == node`
        // invariant.
        bytes32 oldLite = _liteLinks[fullNode];
        bytes32 oldFull = _fullClaims[liteLabelhash];
        if (oldLite != bytes32(0) && oldLite != liteLabelhash) {
            delete _fullClaims[oldLite];
        }
        if (oldFull != bytes32(0) && oldFull != fullNode) {
            delete _liteLinks[oldFull];
        }
        _liteLinks[fullNode] = liteLabelhash;
        _fullClaims[liteLabelhash] = fullNode;
        emit LiteLinkUpdated(fullNode, liteLabelhash);
    }

    /// @inheritdoc IDotnsPopResolver
    function chatKey(bytes32 node) external view override returns (bytes memory) {
        return _chatKeys[node];
    }

    /// @inheritdoc IDotnsPopResolver
    function liteLink(bytes32 fullNode) external view override returns (bytes32) {
        return _liteLinks[fullNode];
    }

    /// @inheritdoc IDotnsPopResolver
    function fullClaim(bytes32 liteLabelhash) external view override returns (bytes32) {
        return _fullClaims[liteLabelhash];
    }

    /// @notice Returns implementation version.
    /// @dev Bumped on every upgrade. Used by deployment scripts as a
    ///      post-upgrade assertion target.
    /// @return versionString Current version string.
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.0.0";
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
