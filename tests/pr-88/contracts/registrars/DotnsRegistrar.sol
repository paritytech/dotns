// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    ERC721Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";

import {IDotnsRegistrar} from "./IDotnsRegistrar.sol";
import {IDotnsRegistrarController} from "./IDotnsRegistrarController.sol";
import {IDotnsProtocolRegistry} from "../registry/IDotnsProtocolRegistry.sol";
import {Store} from "../store/Store.sol";
import {IStoreFactory} from "../store/IStoreFactory.sol";
import {StoreUtils} from "../utils/StoreUtils.sol";
import {StringUtils} from "../utils/StringUtils.sol";
import {IDotnsReverseResolver} from "../resolvers/IDotnsReverseResolver.sol";

/// @title Dotns Registrar
/// @notice ERC721-backed registrar implementing permanent name ownership.
/// @dev This contract is deliberately policy-free.
///      Transfers are supported to allow ownership changes without registry hooks.
///
/// @dev Store writes on transfer:
///      When an ERC721 name token is transferred between non-zero addresses (i.e. not mint or burn),
///      the registrar writes the label to the recipient's Store using the label stored in `_labels`.
///      This ensures the recipient's Store contains a record of every name they have received.
///      Stores are immutable (locked by DotNS controllers), so the sender's entry is not removed.
///
/// @custom:security-contact admin@parity.io
contract DotnsRegistrar is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ERC721Upgradeable,
    IDotnsRegistrar
{
    using StoreUtils for IStoreFactory;
    using StringUtils for *;

    /// @notice Mapping of authorised controller addresses.
    /// @dev Controllers may call `register`.
    mapping(IDotnsRegistrarController controller => bool exists) public controllers;

    /// @notice Protocol-level address registry for all DotNS contracts.
    /// @dev Used to resolve sibling contract addresses (store factory, controller, registry)
    ///      without storing individual references.
    IDotnsProtocolRegistry public protocolRegistry;

    /// @notice DEPRECATED as of v1.2.0: Previously stored labelhashes per token ID.
    /// @dev Retained for UUPS storage layout compatibility. No longer written to.
    ///      The labelhash is now derived on-the-fly from `_labels[tokenId]` via `keccak256(bytes(label))`.
    ///      REMOVE this mapping when deploying to a new environment (fresh deploy, not upgrade).
    /// @custom:oz-retyped-from mapping(uint256 => bytes32)
    mapping(uint256 tokenId => bytes32 labelhash) private _labelhashes;

    /// @notice Human-readable label per token ID. Single source of truth for name data.
    /// @dev Stored at registration time. Used during transfers to write the label directly
    ///      to the recipient's Store without needing to read from the sender's Store.
    ///      The labelhash can always be derived as `keccak256(bytes(label))`.
    mapping(uint256 tokenId => string label) private _labels;

    /// @notice Namehash of the .dot TLD node.
    bytes32 private constant DOT_NODE =
        0x3fce7d1364a893e213bc4212792b517ffc88f5b13b86c8ef9c8d390c3a1370ce;

    /// @notice Well-known protocol registry key for the store factory.
    /// casting to 'bytes32' is safe because the string fits in 32 bytes.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant KEY_STORE_FACTORY = bytes32("storeFactory");

    /// @notice Well-known protocol registry key for the registrar controller.
    /// casting to 'bytes32' is safe because the string fits in 32 bytes.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant KEY_CONTROLLER = bytes32("controller");

    /// @notice Well-known protocol registry key for the forward registry.
    /// casting to 'bytes32' is safe because the string fits in 32 bytes.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant KEY_REGISTRY = bytes32("registry");

    /// @notice Well-known protocol registry key for the reverse resolver.
    /// casting to 'bytes32' is safe because the string fits in 32 bytes.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant KEY_REVERSE_RESOLVER = bytes32("reverseResolver");

    /// @dev Reserved storage space to allow for layout changes in the future.
    uint256[47] private __gap;

    /// @notice Restricts function access to authorised controllers.
    modifier onlyController() {
        _onlyController();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the registrar.
    /// @dev Uses OpenZeppelin upgradeable initializers.
    /// @param name ERC721 token name.
    /// @param symbol ERC721 token symbol.
    function initialize(string calldata name, string calldata symbol) external initializer {
        __Ownable_init(msg.sender);
        __ERC721_init(name, symbol);
    }

    /// @inheritdoc IDotnsRegistrar
    function updateProtocolRegistry(IDotnsProtocolRegistry registry) external override onlyOwner {
        protocolRegistry = registry;
        emit ProtocolRegistryUpdated(registry);
    }

    /// @inheritdoc IDotnsRegistrar
    function addController(IDotnsRegistrarController controller) external onlyOwner {
        controllers[controller] = true;
        emit ControllerAdded(controller);
    }

    /// @inheritdoc IDotnsRegistrar
    function removeController(IDotnsRegistrarController controller) external onlyOwner {
        controllers[controller] = false;
        emit ControllerRemoved(controller);
    }

    /// @inheritdoc IDotnsRegistrar
    function available(uint256 id) public view override returns (bool isAvailable) {
        return !_exists(id);
    }

    /// @inheritdoc IDotnsRegistrar
    function register(
        uint256 id,
        address owner,
        string calldata label
    )
        external
        override
        onlyController
    {
        require(available(id), NameNotAvailable(id));
        _labels[id] = label;
        _mint(owner, id);
        emit NameRegistered(id, owner);
    }

    /// @inheritdoc IDotnsRegistrar
    function syncLabel(uint256 tokenId, string calldata label) external override {
        require(_exists(tokenId), NameNotAvailable(tokenId));
        require(ownerOf(tokenId) == msg.sender, NotTokenOwner(msg.sender, tokenId));
        require(bytes(_labels[tokenId]).length == 0, LabelAlreadySet(tokenId));
        require(label.isSingleLabel(), InvalidLabel());

        bytes32 labelhash;
        bytes32 node;
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            let len := label.length
            calldatacopy(pointer, label.offset, len)
            labelhash := keccak256(pointer, len)
            mstore(pointer, DOT_NODE)
            mstore(add(pointer, 0x20), labelhash)
            node := keccak256(pointer, 0x40)
        }
        require(uint256(node) == tokenId, LabelMismatch(tokenId));

        _labels[tokenId] = label;
        emit LabelSynced(tokenId, label);
    }

    /// @notice Returns implementation version.
    /// @return versionString Current version string.
    function version() external pure virtual returns (string memory versionString) {
        versionString = "1.2.0";
    }

    /// @notice Checks whether a token ID exists.
    /// @param tokenId Token identifier.
    /// @return True if the token exists.
    function _exists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    /// @notice Internal function to check for controller access.
    function _onlyController() internal view {
        require(controllers[IDotnsRegistrarController(msg.sender)], NotController(msg.sender));
    }

    /// @inheritdoc ERC721Upgradeable
    /// @dev Additionally ensures the recipient has a Store and writes the transferred label
    ///      to it when both `from` and `to` are non-zero and a protocol registry has been configured.
    function _update(
        address to,
        uint256 tokenId,
        address auth
    )
        internal
        override
        returns (address from)
    {
        from = super._update(to, tokenId, auth);

        if (from != address(0) && from != to && address(protocolRegistry) != address(0)) {
            _clearFormerPrimaryName(from, tokenId);
        }

        if (from != address(0) && to != address(0) && address(protocolRegistry) != address(0)) {
            _syncRecipientStore(to, tokenId);
        }

        return from;
    }

    function _clearFormerPrimaryName(address from, uint256 tokenId) internal {
        string memory label = _labels[tokenId];
        if (bytes(label).length == 0) return;

        IDotnsReverseResolver reverse =
            IDotnsReverseResolver(protocolRegistry.get(KEY_REVERSE_RESOLVER));
        string memory currentReverse = reverse.nameOf(from);
        string memory fullName = string.concat(label, ".dot");

        if (_stringHash(currentReverse) == _stringHash(fullName)) {
            reverse.setReverseName(from, "");
        }
    }

    /// @notice Ensures the recipient has a Store and writes the label to it if available.
    /// @dev Deploys a Store for the recipient via `getOrCreateStore` when one does not exist,
    ///      then writes the label entry if `_labels[tokenId]` is populated and the key
    ///      does not already have a value (locked entries are skipped).
    ///      Silently returns if the store factory is not set.
    /// @param to Address of the transfer recipient.
    /// @param tokenId The transferred token identifier.
    function _syncRecipientStore(address to, uint256 tokenId) internal {
        IStoreFactory factory = IStoreFactory(protocolRegistry.get(KEY_STORE_FACTORY));
        if (address(factory) == address(0)) return;

        Store toStore = Store(address(factory.getDeployedStore(to)));

        if (address(toStore) == address(0)) {
            address[] memory storeControllers = new address[](3);
            storeControllers[0] = address(this);
            storeControllers[1] = protocolRegistry.get(KEY_CONTROLLER);
            storeControllers[2] = protocolRegistry.get(KEY_REGISTRY);

            toStore = factory.getOrCreateStore(storeControllers, to);
        }

        string memory label = _labels[tokenId];
        if (bytes(label).length > 0) {
            bytes32 labelhash;
            assembly ("memory-safe") {
                labelhash := keccak256(add(label, 0x20), mload(label))
            }
            bytes32 storeKey = StoreUtils.storeKey(labelhash);
            if (bytes(toStore.getValueFor(to, storeKey)).length == 0) {
                toStore.setValueFor(to, storeKey, string.concat(label, ".dot"));
            }
        }
    }

    function _stringHash(string memory value) internal pure returns (bytes32 hash) {
        assembly ("memory-safe") {
            hash := keccak256(add(value, 0x20), mload(value))
        }
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
