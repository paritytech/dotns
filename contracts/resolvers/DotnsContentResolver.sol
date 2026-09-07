// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    ERC165Upgradeable
} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";

import {IDotnsRegistry} from "../registry/IDotnsRegistry.sol";
import {IDotnsContentResolver} from "./IDotnsContentResolver.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "../utils/DotnsConstants.sol";

/// @title Dotns Content Resolver
/// @notice Implements `IDotnsContentResolver` interface with content hash, text records, and
/// operator approvals.
/// @dev Writes are gated on the registry's authorisation for the node (owner or registrar-level
///      approval) or on a resolver-local operator the owner has approved, rather than on a
///      privileged writer address. Content records are user-managed metadata, so write authority
///      follows the node owner across transfers and honours the same delegates the registry
///      recognises.
/// @custom:security-contact admin@parity.io
contract DotnsContentResolver is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC165Upgradeable,
    IDotnsContentResolver
{
    /// @notice Stores all content hash mappings
    mapping(bytes32 node => bytes contentHash) private contenthashes;

    /// @notice Stores all text records
    mapping(bytes32 node => mapping(string key => string value)) private textRecords;

    /// @notice Store all approval mapping
    mapping(address owner => mapping(address operator => bool approved)) private operators;

    /// @notice Protocol-level address registry for all DotNS contracts.
    IDotnsProtocolRegistry public protocolRegistry;

    /// @dev Reserved storage space to allow for layout changes in the future.
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialises the content resolver.
    /// @dev Runs once through the UUPS proxy; a repeat call reverts with
    ///      @custom:reverts InvalidInitialization. Emits @custom:emits OwnershipTransferred when
    ///      `msg.sender` is recorded as the initial owner and @custom:emits Initialized once
    ///      setup completes.
    /// @param registry Protocol-level address registry used to resolve sibling contracts.
    function initialize(IDotnsProtocolRegistry registry) external initializer {
        __Ownable_init(msg.sender);
        __ERC165_init();
        protocolRegistry = registry;
    }

    /// @inheritdoc IDotnsContentResolver
    function setContenthash(bytes32 node, bytes calldata hash) external override {
        _requireNodeOwnerOrOperator(node);
        contenthashes[node] = hash;
        emit ContentHashUpdated(node, hash);
    }

    /// @inheritdoc IDotnsContentResolver
    function contenthash(bytes32 node) external view override returns (bytes memory hash) {
        return contenthashes[node];
    }

    /// @inheritdoc IDotnsContentResolver
    function setText(bytes32 node, string calldata key, string calldata value) external override {
        _requireNodeOwnerOrOperator(node);
        textRecords[node][key] = value;
        emit TextUpdated(node, key, value);
    }

    /// @inheritdoc IDotnsContentResolver
    function text(
        bytes32 node,
        string calldata key
    )
        external
        view
        override
        returns (string memory value)
    {
        return textRecords[node][key];
    }

    /// @inheritdoc IDotnsContentResolver
    function setApprovalForAll(address operator, bool approved) external override {
        operators[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    /// @inheritdoc IDotnsContentResolver
    function isApprovedForAll(
        address owner,
        address operator
    )
        external
        view
        override
        returns (bool)
    {
        return operators[owner][operator];
    }

    /// @notice Ensures the caller may write records for `node`.
    /// @dev Authority is granted to the node owner, to a resolver-local operator the owner has
    ///      approved for all of their records, or to any address the registry deems authorised
    ///      for the node. Delegating through the registry means a single registrar-level
    ///      approval (ERC-721 owner / approved / operator-for-all) also confers record-write
    ///      authority, while the resolver-local operator mapping remains a narrower record-only
    ///      delegation that grants no power over ownership or transfers. The cheap owner and
    ///      local-operator checks run before the cross-contract registry call.
    /// @param node Node identifier.
    function _requireNodeOwnerOrOperator(bytes32 node) internal view {
        IDotnsRegistry _registry = IDotnsRegistry(protocolRegistry.get(DotnsConstants.REGISTRY));
        address nodeOwner = _registry.owner(node);
        require(
            msg.sender == nodeOwner || operators[nodeOwner][msg.sender]
                || _registry.isAuthorised(node, msg.sender),
            NotAuthorised(node, msg.sender)
        );
    }

    /// @notice Returns implementation version.
    /// @return versionString Current version string.
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.0.0";
    }

    /// @inheritdoc ERC165Upgradeable
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IDotnsContentResolver).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
