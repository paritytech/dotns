// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {PopRules, IPopRules} from "../../contracts/pop/PopRules.sol";
import {DotnsRegistrar, IDotnsRegistrar} from "../../contracts/registrars/DotnsRegistrar.sol";
import {
    DotnsRegistrarController,
    IDotnsRegistrarController
} from "../../contracts/registrars/DotnsRegistrarController.sol";
import {
    DotnsPopController,
    IDotnsPopController
} from "../../contracts/registrars/DotnsPopController.sol";
import {IDotnsController} from "../../contracts/registrars/IDotnsController.sol";
import {DotnsRegistry, IDotnsRegistry} from "../../contracts/registry/DotnsRegistry.sol";
import {DotnsResolver} from "../../contracts/resolvers/DotnsResolver.sol";
import {DotnsContentResolver} from "../../contracts/resolvers/DotnsContentResolver.sol";
import {
    DotnsReverseResolver,
    IDotnsReverseResolver
} from "../../contracts/resolvers/DotnsReverseResolver.sol";
import {DotnsPopResolver} from "../../contracts/resolvers/DotnsPopResolver.sol";
import {Store} from "../../contracts/store/Store.sol";
import {StoreFactory, IStoreFactory} from "../../contracts/store/StoreFactory.sol";
import {
    DotnsProtocolRegistry,
    IDotnsProtocolRegistry
} from "../../contracts/registry/DotnsProtocolRegistry.sol";
import {DotnsNameEscrow} from "../../contracts/escrow/DotnsNameEscrow.sol";
import {StoreUtils} from "../../contracts/utils/StoreUtils.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {LabelUtils} from "../../contracts/utils/LabelUtils.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @title BaseDotns
/// @notice Common Foundry test base for deploying a DotNS stack behind UUPS proxies.
/// @dev Deploys and wires the core DotNS contracts used by test suites:
///      - StoreFactory: per-user Store instances used for immutable registration writes
///      - DotnsRegistrar: ERC721-backed registrar used to allocate label ownership
///      - DotnsRegistry: forward registry used to set subnode ownership under .dot
///      - DotnsReverseResolver: reverse resolver used to set default reverse records
///      - DotnsContentResolver: resolver used for content records
///      - PopRules: PoP rules and spam-pricing oracle
///      - DotnsRegistrarController: commit–reveal controller orchestrating registration flow
///      - DotnsNameEscrow: escrow for refundable deposits and name release lifecycle
abstract contract BaseDotns is Test {
    /// @notice Test user account: ed.
    address public ed;

    /// @notice Test user account: leonardo.
    address public leonardo;

    /// @notice Test user account: tiago.
    address public tiago;

    /// @notice Test user account: owner/admin used to deploy and configure contracts.
    address public owner;

    /// @notice Default native balance allocated to test users.
    uint256 public constant DEFAULT_BALANCE = 99_999_999_999_999 ether;

    /// @notice Deployed PoP oracle instance.
    PopRules public popRules;

    /// @notice Deployed DotNS registrar instance.
    DotnsRegistrar public dotnsRegistrar;

    /// @notice Deployed registrar controller instance.
    DotnsRegistrarController public dotnsRegistrarController;

    /// @notice Deployed forward registry instance.
    DotnsRegistry public dotnsRegistry;

    /// @notice Deployed forward resolver instance.
    DotnsResolver public dotnsResolver;

    /// @notice Deployed content resolver instance.
    DotnsContentResolver public dotnsContentResolver;

    /// @notice Deployed reverse resolver instance.
    DotnsReverseResolver public dotnsReverseResolver;

    /// @notice Deployed PoP resolver instance (chat keys + lite links).
    DotnsPopResolver public dotnsPopResolver;

    /// @notice Deployed PoP controller instance (gateway-driven lite/full issuance).
    DotnsPopController public dotnsPopController;

    /// @notice Test account representing the configured PoP gateway signer.
    /// @dev Auth is now signature-based: the controller recovers an EIP-712
    ///      signature and compares the signer against
    ///      `DotnsProtocolRegistry.POP_GATEWAY`. Tests therefore need the
    ///      private key, not just the address.
    address public popGateway;

    /// @notice Private key matching `popGateway`, used by tests to sign
    ///         EIP-712 gateway authorizations.
    uint256 public popGatewayPk;

    /// @notice Default reservation duration used by the PoP controller.
    uint64 public constant DEFAULT_RESERVATION_DURATION = 7 days;

    /// @notice Deployed Store factory instance.
    StoreFactory public storeFactory;

    /// @notice Deployed protocol registry instance.
    DotnsProtocolRegistry public protocolRegistry;

    /// @notice Deployed name escrow instance.
    DotnsNameEscrow public dotnsNameEscrow;

    /// @notice Rent price applied to PoP NoStatus users for spam resistance.
    /// @dev This value is passed into PopRules initialization in this base test.
    uint256 public constant RENT_PRICE = 2e15 wei;

    /// @notice Default escrow cooldown used in tests.
    uint256 public constant ESCROW_COOLDOWN = 7 days;

    /// @notice Zero hash constant
    bytes32 public constant ZERO_HASH = bytes32(0);

    // Classification-valid labels for the PoP path (post PopRules enforcement).
    // baselength 7 with 2 trailing digits classifies as PopLite.
    string internal constant LITE_LABEL_A = "aliceli01";
    string internal constant LITE_LABEL_B = "alicoli02";
    string internal constant LITE_LABEL_C = "boblilu03";
    string internal constant LITE_LABEL_D = "carolli04";
    // baselength 8 with no trailing digits classifies as PopFull.
    string internal constant BASE_LABEL_A = "alicebob";
    string internal constant BASE_LABEL_B = "wonderla";
    string internal constant BASE_LABEL_C = "carolboy";
    // baselength >= 9 with 2 trailing digits classifies as NoStatus.
    string internal constant NOSTATUS_LABEL_A = "nostatususer01";
    string internal constant NOSTATUS_LABEL_B = "anothernostatus02";

    /// @notice Label hash for "dot".
    /// @dev Computed during setup as `keccak256(bytes("dot"))`.
    bytes32 public dotLabel;

    /// @notice Node hash for the ".dot" TLD.
    /// @dev Computed during setup as `_namehash(ZERO_HASH, dotLabel)`.
    bytes32 public dotNode;

    /// @notice Default node hash for the ".dot" TLD.
    /// @dev Included to cross-check against computed `dotNode` where relevant.
    bytes32 private constant DOT_NODE = DotnsConstants.DOT_NODE;

    function setUp() public virtual noGasMetering {
        vm.warp(365 days);

        ed = _createUser("ed");
        leonardo = _createUser("leonardo");
        tiago = _createUser("tiago");
        owner = _createUser("owner");
        (popGateway, popGatewayPk) = makeAddrAndKey("popGateway");
        vm.deal(popGateway, DEFAULT_BALANCE);
        vm.label(popGateway, "popGateway");

        dotLabel = keccak256(bytes("dot"));
        dotNode = _namehash(ZERO_HASH, dotLabel);

        vm.startPrank(owner);

        storeFactory = new StoreFactory();
        vm.label(address(storeFactory), "StoreFactory");

        address dotnsRegistrarAddress = Upgrades.deployUUPSProxy(
            "DotnsRegistrar.sol:DotnsRegistrar",
            abi.encodeCall(DotnsRegistrar.initialize, ("Dotns", "Dotns"))
        );
        dotnsRegistrar = DotnsRegistrar(dotnsRegistrarAddress);
        vm.label(dotnsRegistrarAddress, "DotnsRegistrar");

        address dotnsReverseResolverAddress = Upgrades.deployUUPSProxy(
            "DotnsReverseResolver.sol:DotnsReverseResolver",
            abi.encodeCall(DotnsReverseResolver.initialize, ())
        );
        dotnsReverseResolver = DotnsReverseResolver(dotnsReverseResolverAddress);
        vm.label(dotnsReverseResolverAddress, "DotnsReverseResolver");

        address dotnsRegistryAddress = Upgrades.deployUUPSProxy(
            "DotnsRegistry.sol:DotnsRegistry",
            abi.encodeCall(
                DotnsRegistry.initialize,
                (
                    IDotnsRegistrar(dotnsRegistrarAddress),
                    IDotnsReverseResolver(dotnsReverseResolverAddress),
                    storeFactory
                )
            )
        );
        dotnsRegistry = DotnsRegistry(dotnsRegistryAddress);
        vm.label(dotnsRegistryAddress, "DotnsRegistry");

        address dotnsContentResolverAddress = Upgrades.deployUUPSProxy(
            "DotnsContentResolver.sol:DotnsContentResolver",
            abi.encodeCall(DotnsContentResolver.initialize, (IDotnsRegistry(dotnsRegistryAddress)))
        );
        dotnsContentResolver = DotnsContentResolver(dotnsContentResolverAddress);
        vm.label(dotnsContentResolverAddress, "DotnsContentResolver");

        address popRulesAddress = Upgrades.deployUUPSProxy(
            "PopRules.sol:PopRules", abi.encodeCall(PopRules.initialize, (RENT_PRICE))
        );
        popRules = PopRules(popRulesAddress);
        vm.label(popRulesAddress, "PopRules");

        address dotnsResolverAddress = Upgrades.deployUUPSProxy(
            "DotnsResolver.sol:DotnsResolver",
            abi.encodeCall(DotnsResolver.initialize, (IDotnsRegistry(dotnsRegistryAddress)))
        );
        dotnsResolver = DotnsResolver(dotnsResolverAddress);
        vm.label(dotnsResolverAddress, "DotnsResolver");

        address dotnsRegistrarControllerAddress = Upgrades.deployUUPSProxy(
            "DotnsRegistrarController.sol:DotnsRegistrarController",
            abi.encodeCall(
                DotnsRegistrarController.initialize,
                (
                    IDotnsRegistrar(dotnsRegistrarAddress),
                    IDotnsRegistry(dotnsRegistryAddress),
                    IDotnsReverseResolver(dotnsReverseResolverAddress),
                    IPopRules(popRulesAddress),
                    IStoreFactory(address(storeFactory)),
                    6 seconds,
                    1 days
                )
            )
        );
        dotnsRegistrarController = DotnsRegistrarController(dotnsRegistrarControllerAddress);
        vm.label(dotnsRegistrarControllerAddress, "DotnsRegistrarController");

        dotnsRegistrar.addController(IDotnsController(dotnsRegistrarControllerAddress));

        address protocolRegistryAddress = Upgrades.deployUUPSProxy(
            "DotnsProtocolRegistry.sol:DotnsProtocolRegistry",
            abi.encodeCall(DotnsProtocolRegistry.initialize, ())
        );
        protocolRegistry = DotnsProtocolRegistry(protocolRegistryAddress);
        vm.label(protocolRegistryAddress, "DotnsProtocolRegistry");

        address dotnsPopResolverAddress = Upgrades.deployUUPSProxy(
            "DotnsPopResolver.sol:DotnsPopResolver",
            abi.encodeCall(
                DotnsPopResolver.initialize, (IDotnsProtocolRegistry(protocolRegistryAddress))
            )
        );
        dotnsPopResolver = DotnsPopResolver(dotnsPopResolverAddress);
        vm.label(dotnsPopResolverAddress, "DotnsPopResolver");

        address dotnsPopControllerAddress = Upgrades.deployUUPSProxy(
            "DotnsPopController.sol:DotnsPopController",
            abi.encodeCall(
                DotnsPopController.initialize,
                (IDotnsProtocolRegistry(protocolRegistryAddress), DEFAULT_RESERVATION_DURATION)
            )
        );
        dotnsPopController = DotnsPopController(dotnsPopControllerAddress);
        vm.label(dotnsPopControllerAddress, "DotnsPopController");

        dotnsRegistrar.addController(IDotnsController(dotnsPopControllerAddress));

        address dotnsNameEscrowAddress = Upgrades.deployUUPSProxy(
            "DotnsNameEscrow.sol:DotnsNameEscrow",
            abi.encodeCall(
                DotnsNameEscrow.initialize,
                (IDotnsProtocolRegistry(protocolRegistryAddress), ESCROW_COOLDOWN)
            )
        );
        dotnsNameEscrow = DotnsNameEscrow(payable(dotnsNameEscrowAddress));
        vm.label(dotnsNameEscrowAddress, "DotnsNameEscrow");

        protocolRegistry.set(DotnsConstants.REGISTRAR, dotnsRegistrarAddress);
        protocolRegistry.set(DotnsConstants.CONTROLLER, dotnsRegistrarControllerAddress);
        protocolRegistry.set(DotnsConstants.REGISTRY, dotnsRegistryAddress);
        protocolRegistry.set(DotnsConstants.REVERSE_RESOLVER, dotnsReverseResolverAddress);
        protocolRegistry.set(DotnsConstants.POP_RULES, popRulesAddress);
        protocolRegistry.set(DotnsConstants.STORE_FACTORY, address(storeFactory));
        protocolRegistry.set(DotnsConstants.RESOLVER, dotnsResolverAddress);
        protocolRegistry.set(DotnsConstants.CONTENT_RESOLVER, dotnsContentResolverAddress);
        protocolRegistry.set(DotnsConstants.POP_RESOLVER, dotnsPopResolverAddress);
        protocolRegistry.set(DotnsConstants.POP_CONTROLLER, dotnsPopControllerAddress);
        protocolRegistry.set(DotnsConstants.POP_GATEWAY, popGateway);
        protocolRegistry.set(DotnsConstants.NAME_ESCROW, dotnsNameEscrowAddress);

        dotnsRegistrar.updateProtocolRegistry(IDotnsProtocolRegistry(address(protocolRegistry)));
        dotnsRegistrarController.updateProtocolRegistry(
            IDotnsProtocolRegistry(address(protocolRegistry))
        );
        dotnsRegistry.updateProtocolRegistry(IDotnsProtocolRegistry(address(protocolRegistry)));
        dotnsReverseResolver.updateProtocolRegistry(
            IDotnsProtocolRegistry(address(protocolRegistry))
        );
        dotnsResolver.updateProtocolRegistry(IDotnsProtocolRegistry(address(protocolRegistry)));
        dotnsContentResolver.updateProtocolRegistry(
            IDotnsProtocolRegistry(address(protocolRegistry))
        );
        popRules.updateProtocolRegistry(IDotnsProtocolRegistry(address(protocolRegistry)));

        vm.stopPrank();
        vm.warp(block.timestamp + 365 days);
    }

    /// @notice Computes the namehash of `parent` and `labelhash`.
    /// @dev Thin wrapper around {LabelUtils-namehashUnder} so tests do not
    ///      reimplement the assembly composition.
    /// @param parent The parent node hash.
    /// @param labelhash The labelhash.
    /// @return node The resulting node hash.
    function _namehash(bytes32 parent, bytes32 labelhash) internal pure returns (bytes32 node) {
        node = LabelUtils.namehashUnder(parent, labelhash);
    }

    /// @notice Computes the ERC721 tokenId used by DotnsRegistrar for a given label.
    /// @dev DotnsRegistrar mints tokenId = uint256(node), where node = namehash(DOT_NODE, labelhash).
    ///      This helper prevents tests from accidentally using uint256(node) as the tokenId.
    /// @param label The label to compute for (without the `.dot` suffix).
    /// @return tokenId The ERC721 tokenId (uint256(node)).
    function _tokenIdForLabel(string memory label) internal pure returns (uint256 tokenId) {
        tokenId = uint256(_nodeOf(label));
    }

    /// @notice Computes `namehash(DOT_NODE, keccak256(label))` for a flat label.
    /// @dev Shared across test suites that need the node identifier for a .dot label.
    /// @param label Label (without the `.dot` suffix).
    /// @return node The node identifier under the `.dot` TLD.
    function _nodeOf(string memory label) internal pure returns (bytes32 node) {
        node = LabelUtils.namehashUnder(DOT_NODE, LabelUtils.labelhashMemory(label));
    }

    /// @dev Returns a valid 65-byte chat key seeded with `seed`. Format mimics the
    ///      uncompressed secp256k1 encoding (1 prefix byte + 32 X + 32 Y) so the
    ///      resolver's length guard is satisfied.
    function _validChatKey(bytes1 seed) internal pure returns (bytes memory key) {
        key = new bytes(65);
        key[0] = 0x04;
        for (uint256 i = 1; i < 65; i++) {
            key[i] = seed;
        }
    }

    /// @notice Grants PopFull status to `who` on the PoP rules oracle.
    function _grantPopFull(address who) internal {
        vm.prank(who);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopFull);
    }

    /// @notice Grants PopLite status to `who` on the PoP rules oracle.
    function _grantPopLite(address who) internal {
        vm.prank(who);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopLite);
    }

    /// @notice Grants NoStatus (default) to `who` on the PoP rules oracle.
    function _grantNoStatus(address who) internal {
        vm.prank(who);
        popRules.setUserPopStatus(IPopRules.PopStatus.NoStatus);
    }

    /// @dev EIP-712 type hash for `ReserveLiteName`. Mirrors the value declared
    ///      in `DotnsPopController.sol`; kept literal so the test catches any
    ///      drift between the contract and the harness.
    bytes32 internal constant RESERVE_LITE_TYPEHASH = keccak256(
        "ReserveLiteName(string liteLabel,address user,bytes chatKey,uint256 deadline,uint256 nonce)"
    );

    /// @dev EIP-712 type hash for `ReserveBaseName`.
    bytes32 internal constant RESERVE_BASE_TYPEHASH = keccak256(
        "ReserveBaseName(string liteLabel,address user,bytes chatKey,string reservedBaseLabel,uint256 deadline,uint256 nonce)"
    );

    /// @dev EIP-712 type hash for `RegisterBaseName`. The `Link` struct is
    ///      flattened into the typehash to match the contract.
    bytes32 internal constant REGISTER_BASE_TYPEHASH = keccak256(
        "RegisterBaseName(string label,address user,uint8 linkKind,string linkLiteLabel,bytes linkChatKey,uint256 deadline,uint256 nonce)"
    );

    /// @dev Default validity window applied by gateway-signing helpers.
    uint256 internal constant DEFAULT_AUTH_VALIDITY = 1 hours;

    /// @notice Signs a struct hash as the configured gateway signer.
    /// @dev Reads the controller's EIP-712 domain via `eip712Domain()` so the
    ///      digest matches whatever name/version/chainId/verifyingContract the
    ///      contract is actually using.
    /// @param structHash EIP-712 struct hash of the typed payload.
    /// @return deadline The deadline embedded in the payload (now + 1h).
    /// @return nonce The signer's current nonce read from the controller.
    /// @return sig The 65-byte signature.
    function _signGatewayCall(bytes32 structHash)
        internal
        view
        returns (uint256 deadline, uint256 nonce, bytes memory sig)
    {
        deadline = block.timestamp + DEFAULT_AUTH_VALIDITY;
        nonce = dotnsPopController.gatewayNonces(popGateway);
        bytes32 digest = _eip712Digest(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(popGatewayPk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    /// @notice Builds an EIP-712 digest under the controller's domain.
    function _eip712Digest(bytes32 structHash) internal view returns (bytes32) {
        (
            ,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            ,
        ) = dotnsPopController.eip712Domain();
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
    }

    /// @notice Builds the struct hash for `reserveLiteName`.
    function _reserveLiteStructHash(
        string memory liteLabel,
        address user,
        bytes memory chatKey,
        uint256 deadline,
        uint256 nonce
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                RESERVE_LITE_TYPEHASH,
                keccak256(bytes(liteLabel)),
                user,
                keccak256(chatKey),
                deadline,
                nonce
            )
        );
    }

    /// @notice Builds the struct hash for `reserveBaseName`.
    function _reserveBaseStructHash(
        string memory liteLabel,
        address user,
        bytes memory chatKey,
        string memory reservedBaseLabel,
        uint256 deadline,
        uint256 nonce
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                RESERVE_BASE_TYPEHASH,
                keccak256(bytes(liteLabel)),
                user,
                keccak256(chatKey),
                keccak256(bytes(reservedBaseLabel)),
                deadline,
                nonce
            )
        );
    }

    /// @notice Builds the struct hash for `registerBaseName`.
    function _registerBaseStructHash(
        string memory label,
        address user,
        IDotnsPopController.Link memory link,
        uint256 deadline,
        uint256 nonce
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                REGISTER_BASE_TYPEHASH,
                keccak256(bytes(label)),
                user,
                uint8(link.kind),
                keccak256(bytes(link.liteLabel)),
                keccak256(link.chatKey),
                deadline,
                nonce
            )
        );
    }

    /// @notice Drives `DotnsPopController.reserveLiteName` with a valid gateway
    ///         signature.
    function _reserveLiteAsGateway(
        string memory liteLabel,
        address user,
        bytes memory chatKey
    )
        internal
    {
        uint256 deadline = block.timestamp + DEFAULT_AUTH_VALIDITY;
        uint256 nonce = dotnsPopController.gatewayNonces(popGateway);
        bytes32 structHash = _reserveLiteStructHash(liteLabel, user, chatKey, deadline, nonce);
        bytes memory sig = _sign(structHash);
        dotnsPopController.reserveLiteName(liteLabel, user, chatKey, deadline, nonce, sig);
    }

    /// @notice Drives `DotnsPopController.reserveBaseName` with a valid gateway
    ///         signature.
    /// @dev Replaces the previous `_reservePop` helper.
    function _reservePop(
        address user,
        string memory liteLabel,
        bytes memory chatKey,
        string memory reservedBaseLabel
    )
        internal
    {
        uint256 deadline = block.timestamp + DEFAULT_AUTH_VALIDITY;
        uint256 nonce = dotnsPopController.gatewayNonces(popGateway);
        bytes32 structHash = _reserveBaseStructHash(
            liteLabel, user, chatKey, reservedBaseLabel, deadline, nonce
        );
        bytes memory sig = _sign(structHash);
        dotnsPopController.reserveBaseName(
            liteLabel, user, chatKey, reservedBaseLabel, deadline, nonce, sig
        );
    }

    /// @notice Drives `DotnsPopController.registerBaseName` with a valid gateway
    ///         signature.
    function _registerBaseAsGateway(
        string memory label,
        address user,
        IDotnsPopController.Link memory link
    )
        internal
    {
        uint256 deadline = block.timestamp + DEFAULT_AUTH_VALIDITY;
        uint256 nonce = dotnsPopController.gatewayNonces(popGateway);
        bytes32 structHash = _registerBaseStructHash(label, user, link, deadline, nonce);
        bytes memory sig = _sign(structHash);
        dotnsPopController.registerBaseName(label, user, link, deadline, nonce, sig);
    }

    /// @dev Signs a struct hash under the controller's EIP-712 domain with the
    ///      gateway private key and returns the 65-byte signature.
    function _sign(bytes32 structHash) internal view returns (bytes memory) {
        return _signWith(popGatewayPk, structHash);
    }

    /// @dev Signs a struct hash with an arbitrary private key. Useful for
    ///      negative tests that need a signature from a non-gateway signer.
    function _signWith(uint256 pk, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = _eip712Digest(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Builds a valid auth tail for `reserveLiteName` without making
    ///         the controller call. Used by revert tests that need
    ///         `vm.expectRevert` to land on the controller call itself.
    function _authReserveLite(
        string memory liteLabel,
        address user,
        bytes memory chatKey
    )
        internal
        view
        returns (uint256 deadline, uint256 nonce, bytes memory sig)
    {
        deadline = block.timestamp + DEFAULT_AUTH_VALIDITY;
        nonce = dotnsPopController.gatewayNonces(popGateway);
        sig = _sign(_reserveLiteStructHash(liteLabel, user, chatKey, deadline, nonce));
    }

    /// @notice Builds a valid auth tail for `reserveBaseName`.
    function _authReserveBase(
        string memory liteLabel,
        address user,
        bytes memory chatKey,
        string memory reservedBaseLabel
    )
        internal
        view
        returns (uint256 deadline, uint256 nonce, bytes memory sig)
    {
        deadline = block.timestamp + DEFAULT_AUTH_VALIDITY;
        nonce = dotnsPopController.gatewayNonces(popGateway);
        sig = _sign(
            _reserveBaseStructHash(liteLabel, user, chatKey, reservedBaseLabel, deadline, nonce)
        );
    }

    /// @notice Builds a valid auth tail for `registerBaseName`.
    function _authRegisterBase(
        string memory label,
        address user,
        IDotnsPopController.Link memory link
    )
        internal
        view
        returns (uint256 deadline, uint256 nonce, bytes memory sig)
    {
        deadline = block.timestamp + DEFAULT_AUTH_VALIDITY;
        nonce = dotnsPopController.gatewayNonces(popGateway);
        sig = _sign(_registerBaseStructHash(label, user, link, deadline, nonce));
    }

    /// @notice Constructs a `Link` that inherits the chat key from a prior lite label.
    function _linkWithLite(string memory liteLabel)
        internal
        pure
        returns (IDotnsPopController.Link memory)
    {
        return IDotnsPopController.Link({
            kind: IDotnsPopController.LinkKind.LiteUsername, liteLabel: liteLabel, chatKey: ""
        });
    }

    /// @notice Constructs a `Link` carrying a fresh chat key (no lite inheritance).
    function _linkFresh(bytes memory chatKey)
        internal
        pure
        returns (IDotnsPopController.Link memory)
    {
        return IDotnsPopController.Link({
            kind: IDotnsPopController.LinkKind.None, liteLabel: "", chatKey: chatKey
        });
    }

    /// @notice Authorises the calling test contract on the registrar's controller set.
    /// @dev PopRules' `_onlyRegistry` trusts `DotnsRegistrar.controllers`, so unit
    ///      tests that exercise `reserveBaseName` / `reserveBaseNameForPop` /
    ///      `releaseBaseName` directly have to be registered. Single helper keeps
    ///      the `vm.prank(owner)` + `addController` boilerplate in one place.
    function _authoriseTestAsController() internal {
        vm.prank(owner);
        dotnsRegistrar.addController(IDotnsController(address(this)));
    }

    /// @notice Creates a new test user and funds it with DEFAULT_BALANCE.
    /// @dev Uses Foundry's `makeAddr` to derive a deterministic address and labels it in traces.
    /// @param name Human-readable label used to derive and label the address.
    /// @return user Newly created payable address.
    function _createUser(string memory name) internal returns (address payable user) {
        user = payable(makeAddr(name));
        vm.deal({account: user, newBalance: DEFAULT_BALANCE});
        vm.label(user, name);
    }

    /// @notice Computes the commitment hash for a registration.
    /// @param registration Registration parameters.
    /// @return commitmentHash Commitment hash.
    function _computeCommitmentHash(IDotnsRegistrarController.Registration memory registration)
        internal
        view
        returns (bytes32 commitmentHash)
    {
        commitmentHash = dotnsRegistrarController.makeCommitment(registration);
    }

    /// @notice Submits a commitment for a registration.
    /// @dev Uses `registration.owner` as the committing account.
    /// @param registration Registration parameters.
    function _commitRegistration(IDotnsRegistrarController.Registration memory registration)
        internal
    {
        bytes32 commitmentHash = _computeCommitmentHash(registration);
        vm.prank(registration.owner);
        dotnsRegistrarController.commit(commitmentHash);
    }

    /// @notice Submits a commitment and advances time past the controller minimum commitment age.
    /// @param registration Registration parameters.
    function _commitRegistrationAndWaitMinimumAge(
        IDotnsRegistrarController.Registration memory registration
    )
        internal
    {
        _commitRegistration(registration);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);
    }

    /// @notice Submits a commitment, waits for the minimum age, then registers with the exact oracle price.
    /// @dev Prices are obtained via `popRules.priceWithCheck(label, owner)`.
    /// @param registration Registration parameters.
    function _commitRegistrationAndRegister(
        IDotnsRegistrarController.Registration memory registration
    )
        internal
    {
        _commitRegistrationAndWaitMinimumAge(registration);

        IPopRules.PriceWithMeta memory priceMetadata =
            popRules.priceWithCheck(registration.label, registration.owner);

        vm.prank(registration.owner);
        dotnsRegistrarController.register{value: priceMetadata.price}(registration);
    }

    /// @notice Minimal commit–reveal helper aligned to IDotnsRegistrarController.
    /// @param label Label to register.
    /// @param nameOwner Address to assign as owner.
    /// @param reserveName Whether the name is reserved.
    function _commitAndRegister(string memory label, address nameOwner, bool reserveName) internal {
        bytes32 secret = keccak256(abi.encodePacked(label, nameOwner, block.timestamp));

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label, owner: nameOwner, secret: secret, reserved: reserveName
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);

        vm.prank(nameOwner);
        dotnsRegistrarController.commit(commitment);

        uint256 minAge = dotnsRegistrarController.minCommitmentAge();
        vm.warp(block.timestamp + minAge + 1);

        uint256 requiredPayment = popRules.priceWithCheck(label, nameOwner).price;

        vm.prank(nameOwner);
        dotnsRegistrarController.register{value: requiredPayment}(registration);
    }

    /// @notice Registers `label` for `labelOwner` under the requested PoP status and returns its node
    /// @dev For NoStatus, no status is set on the oracle.
    ///      For PopLite/PopFull, status is set for `(labelOwner, label)` before commit–reveal.
    /// @param label The label to register (without the `.dot` suffix)
    /// @param labelOwner The address that will own the registered label
    /// @param status The PoP status to set for this label (NoStatus skips setting)
    /// @return node The node identifier for `<label>.dot`
    function _register(
        string memory label,
        address labelOwner,
        IPopRules.PopStatus status
    )
        internal
        returns (bytes32 node)
    {
        if (status != IPopRules.PopStatus.NoStatus) {
            vm.prank(labelOwner);
            popRules.setUserPopStatus(status);
        }

        _commitAndRegister(label, labelOwner, true);

        node = _nodeOf(label);
    }

    /// @notice Ensures a Store exists for `storeOwner`, deploying one if necessary.
    /// @dev If a Store is deployed, it is authorised for the registrar controller
    /// @param storeOwner The address that should own the Store.
    /// @return store The deployed Store instance.
    function _ensureStoreFor(address storeOwner) internal returns (Store store) {
        address deployed = address(storeFactory.getDeployedStore(storeOwner));
        if (deployed != address(0)) {
            return Store(deployed);
        }

        vm.startPrank(storeOwner);

        store = Store(address(storeFactory.deploy()));
        store.authorizeDotnsController(address(dotnsRegistrarController));
        store.authorizeDotnsController(address(dotnsRegistry));
        vm.stopPrank();
    }

    /// @notice Computes the Store key for a registered label.
    /// @dev Delegates to `StoreUtils.storeKey`; single source of truth for the key derivation.
    /// @param labelhash keccak256(label).
    /// @return key Store key used for DotNS-written registration entry.
    function _storeKey(bytes32 labelhash) internal pure returns (bytes32 key) {
        key = StoreUtils.storeKey(labelhash);
    }

    /// @notice Checks whether a string array contains a given string.
    /// @dev Compares by keccak256(bytes(string)) to avoid costly byte-by-byte comparisons.
    /// @param array The array to search.
    /// @param needle The string to find.
    /// @return found True if `needle` is present in `arr`.
    function _contains(
        string[] memory array,
        string memory needle
    )
        internal
        pure
        returns (bool found)
    {
        bytes32 needleHash = keccak256(bytes(needle));
        for (uint256 i = 0; i < array.length; i++) {
            if (keccak256(bytes(array[i])) == needleHash) return true;
        }
        return false;
    }
}
