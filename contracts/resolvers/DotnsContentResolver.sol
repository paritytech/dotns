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

import {IDotnsRegistry} from "../registry/IDotnsRegistry.sol";
import {IDotnsContentResolver} from "./IDotnsContentResolver.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "../utils/DotnsConstants.sol";

/// @title dotNS Content Resolver
/// @notice Implements `IDotnsContentResolver` interface with content hash, text records, and
/// operator approvals.
/// @dev Writes are gated on the registry's authorisation for the node (owner or registrar-level
///      approval) or on a resolver-local operator the owner has approved, rather than on a
///      privileged writer address. Content records are user-managed metadata, so write authority
///      follows the node owner across transfers and honours the same delegates the registry
///      recognises. Each record is stamped with the node's record version from the registry
///      (@custom:function IDotnsRegistry.recordVersion), and a read returns empty unless the node
///      still resolves and the stamp is current, so clearing a name never has to list its text
///      keys.
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

    /// @notice Protocol-level address registry for all dotNS contracts.
    IDotnsProtocolRegistry public protocolRegistry;

    /// @dev Reserved storage space to allow for layout changes in the future.
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256[50] private __gap;

    /// @notice Node => registry record version its content hash was written under.
    /// @dev Zero for every record written before stamps existed, which matches the version every
    ///      node starts at, so those records stay readable until the node is first cleared. The
    ///      same holds for `textVersions`.
    mapping(bytes32 node => uint64 version) private contenthashVersions;

    /// @notice Node => text key => registry record version the value was written under.
    mapping(bytes32 node => mapping(string key => uint64 version)) private textVersions;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialises the content resolver.
    /// @dev Runs once through the UUPS proxy; a repeat call reverts with
    ///      @custom:reverts InvalidInitialization. Emits @custom:emits OwnershipTransferred when
    ///      `msg.sender` is recorded as the initial owner and @custom:emits Initialized once
    ///      setup completes.
    /// @param initialOwner Address that owns the contract once initialised.
    /// @param registry Protocol-level address registry used to resolve sibling contracts.
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

    /// @inheritdoc IDotnsContentResolver
    function setContenthash(bytes32 node, bytes calldata hash) external override {
        uint64 version = _requireNodeOwnerOrOperator(node);
        contenthashes[node] = hash;
        if (contenthashVersions[node] != version) contenthashVersions[node] = version;
        emit ContentHashUpdated(node, hash);
    }

    /// @inheritdoc IDotnsContentResolver
    function contenthash(bytes32 node) external view override returns (bytes memory hash) {
        if (!_isCurrent(node, contenthashVersions[node])) return "";
        return contenthashes[node];
    }

    /// @inheritdoc IDotnsContentResolver
    function setText(bytes32 node, string calldata key, string calldata value) external override {
        uint64 version = _requireNodeOwnerOrOperator(node);
        textRecords[node][key] = value;
        if (textVersions[node][key] != version) textVersions[node][key] = version;
        emit TextUpdated(node, key, key, value);
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
        if (!_isCurrent(node, textVersions[node][key])) return "";
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
    /// @return version Record version of `node`, which the caller stamps the write with.
    function _requireNodeOwnerOrOperator(bytes32 node) internal view returns (uint64 version) {
        IDotnsRegistry _registry = _forwardRegistry();
        address nodeOwner = _registry.owner(node);
        require(
            msg.sender == nodeOwner || operators[nodeOwner][msg.sender]
                || _registry.isAuthorised(node, msg.sender),
            NotAuthorised(node, msg.sender)
        );
        (, version) = _registry.recordVersion(node);
    }

    /// @notice Returns whether a record stamped `stamp` is readable for `node`.
    /// @dev Every getter goes through here. A getter that skipped it would serve records the node
    ///      has cleared, so a new record type must read through it too.
    /// @param node Node identifier.
    /// @param stamp Record version the record was written under.
    /// @return current True when `node` resolves and `stamp` is its current record version.
    function _isCurrent(bytes32 node, uint64 stamp) internal view returns (bool current) {
        (bool live, uint64 version) = _forwardRegistry().recordVersion(node);
        current = live && stamp == version;
    }

    /// @notice Returns the forward registry, resolved lazily so a rewire needs no upgrade here.
    /// @return registry The forward registry.
    function _forwardRegistry() internal view returns (IDotnsRegistry registry) {
        registry = IDotnsRegistry(protocolRegistry.get(DotnsConstants.REGISTRY));
    }

    /// @notice Returns the release this network declares it runs, read live from the protocol
    ///         registry so every dotNS contract reports one synchronised value.
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
        return interfaceId == type(IDotnsContentResolver).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
