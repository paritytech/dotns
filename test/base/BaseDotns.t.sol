// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {PopRules, IPopRules} from "../../contracts/pop/PopRules.sol";
import {DotnsFlatPricing} from "../../contracts/pop/DotnsFlatPricing.sol";
import {DotnsScarcityPricing} from "../../contracts/pop/DotnsScarcityPricing.sol";
import {DotnsCostModelRegistry} from "../../contracts/pop/DotnsCostModelRegistry.sol";
import {IDotnsPricing} from "../../contracts/pop/IDotnsPricing.sol";
import {DotnsRegistrar} from "../../contracts/registrars/DotnsRegistrar.sol";
import {
    DotnsRegistrarController,
    IDotnsRegistrarController
} from "../../contracts/registrars/DotnsRegistrarController.sol";
import {
    DotnsPopController,
    IDotnsPopController
} from "../../contracts/registrars/DotnsPopController.sol";
import {DotnsPopLens} from "../../contracts/registrars/DotnsPopLens.sol";
import {IDotnsPopLens} from "../../contracts/registrars/IDotnsPopLens.sol";
import {IDotnsController} from "../../contracts/registrars/IDotnsController.sol";
import {DotnsRegistry} from "../../contracts/registry/DotnsRegistry.sol";
import {DotnsResolver} from "../../contracts/resolvers/DotnsResolver.sol";
import {DotnsContentResolver} from "../../contracts/resolvers/DotnsContentResolver.sol";
import {DotnsReverseResolver} from "../../contracts/resolvers/DotnsReverseResolver.sol";
import {DotnsPopResolver} from "../../contracts/resolvers/DotnsPopResolver.sol";
import {StoreFactory} from "../../contracts/store/StoreFactory.sol";
import {
    DotnsProtocolRegistry,
    IDotnsProtocolRegistry
} from "../../contracts/registry/DotnsProtocolRegistry.sol";
import {DotnsNameEscrow} from "../../contracts/escrow/DotnsNameEscrow.sol";
import {DotnsNameWhitelist} from "../../contracts/whitelist/DotnsNameWhitelist.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {LabelUtils} from "../../contracts/utils/LabelUtils.sol";
import {ISystem} from "../../contracts/external/revive/ISystem.sol";
import {IPersonhood} from "../../contracts/external/personhood/IPersonhood.sol";
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
///      - DotnsRegistrarController: commit-reveal controller orchestrating registration flow
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

    /// @notice Deployed flat model seeding the cost-model registry as the launch version.
    DotnsFlatPricing public flatPricing;

    /// @notice Deployed scarcity model, a later candidate held for the version-registry suites; not
    ///         the registered default.
    DotnsScarcityPricing public scarcityPricing;

    /// @notice Deployed cost-model registry resolved by PopRules under `COST_MODEL`.
    DotnsCostModelRegistry public costModelRegistry;

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

    /// @notice Deployed PoP lens instance (read-only view over PoP identity data).
    DotnsPopLens public dotnsPopLens;

    /// @notice Selector for the typed reserveLiteName entrypoint.
    bytes4 internal constant SELECTOR_RESERVE_LITE_TYPED =
        bytes4(keccak256("reserveLiteName((string,address,bytes))"));

    /// @notice Selector for the typed reserveBaseName entrypoint.
    bytes4 internal constant SELECTOR_RESERVE_BASE_TYPED =
        bytes4(keccak256("reserveBaseName(((string,address,bytes),string))"));

    /// @notice Selector for the typed reserveBaseNameOnly entrypoint.
    bytes4 internal constant SELECTOR_RESERVE_BASE_ONLY_TYPED =
        bytes4(keccak256("reserveBaseNameOnly((address,string))"));

    /// @notice Selector for the typed registerBaseName entrypoint.
    bytes4 internal constant SELECTOR_REGISTER_BASE_TYPED =
        bytes4(keccak256("registerBaseName((string,address,(uint8,string,bytes)))"));

    /// @notice Default reservation duration used by the PoP controller.
    uint64 public constant DEFAULT_RESERVATION_DURATION = 7 days;

    /// @notice Deployed Store factory instance.
    StoreFactory public storeFactory;

    /// @notice Deployed protocol registry instance.
    DotnsProtocolRegistry public protocolRegistry;

    /// @notice Deployed name escrow instance.
    DotnsNameEscrow public dotnsNameEscrow;

    DotnsNameWhitelist public dotnsNameWhitelist;
    /// @notice Base deposit the flat launch model charges for every admitted name.
    /// @dev Aliased to @custom:constant DotnsConstants.BASE_DEPOSIT so deploy scripts and the test
    ///      base see the same value; downstream test suites reference `BASE_DEPOSIT`
    ///      directly.
    uint256 public constant BASE_DEPOSIT = DotnsConstants.BASE_DEPOSIT;

    /// @notice Price floor F seeded into PopRules initialisation in this base test.
    /// @dev Aliased to @custom:constant DotnsConstants.MIN_PRICE so deploy scripts and the test
    ///      base see the same seed; downstream test suites reference `MIN_PRICE` directly.
    uint256 public constant MIN_PRICE = DotnsConstants.MIN_PRICE;

    /// @notice Default escrow cooldown used in tests. Bounded by the escrow's
    ///         @custom:constant MAX_COOLDOWN ceiling.
    uint256 public constant ESCROW_COOLDOWN = DotnsConstants.ESCROW_COOLDOWN;

    /// @notice Default escrow redeem window used in tests. Bounded by the escrow's
    ///         @custom:constant MAX_REDEEM_WINDOW ceiling.
    uint256 public constant ESCROW_REDEEM_WINDOW = DotnsConstants.ESCROW_REDEEM_WINDOW;

    /// @notice Zero hash constant.
    bytes32 public constant ZERO_HASH = bytes32(0);

    // Classification-valid labels for the PoP path (post PopRules enforcement).
    // A stem of 7 behind a two-digit suffix classifies as PopLite. These carry the gateway's
    // separator, which reaches the chain only through the PoP path: the public path rejects a
    // separator, so a dotted label is always gateway-issued.
    /// @notice PoP lite classification label fixture A.
    string internal constant LITE_LABEL_A = "michael.01";
    /// @notice PoP lite classification label fixture B.
    string internal constant LITE_LABEL_B = "matthew.02";
    /// @notice PoP lite classification label fixture C.
    string internal constant LITE_LABEL_C = "william.03";
    /// @notice PoP lite classification label fixture D.
    string internal constant LITE_LABEL_D = "richard.04";

    // baselength 8 with no trailing digits classifies as PopFull.
    /// @notice PoP full classification label fixture A.
    string internal constant BASE_LABEL_A = "alicebob";
    /// @notice PoP full classification label fixture B.
    string internal constant BASE_LABEL_B = "wonderla";
    /// @notice PoP full classification label fixture C.
    string internal constant BASE_LABEL_C = "carolboy";

    // Measured whole at 11, which is 9 or more, so these classify as NoStatus.
    /// @notice NoStatus classification label fixture A. Eleven characters, measured whole.
    string internal constant NOSTATUS_LABEL_A = "nostatusa01";
    /// @notice NoStatus classification label fixture B. Eleven characters, measured whole.
    string internal constant NOSTATUS_LABEL_B = "nostatusb02";

    /// @notice The bare TLD label the whole suite runs against.
    /// @dev Single definition point for the fixture's TLD. Change this one line to run every test
    ///      under a different network TLD; the registry is initialised with it and all node and
    ///      full-name derivations follow from it (see `_tldNode` and `_nodeOf`).
    string public constant TLD_LABEL = "dot";

    /// @notice Label hash of @custom:constant TLD_LABEL.
    /// @dev Computed during setup as `keccak256(bytes(TLD_LABEL))`.
    bytes32 public dotLabel;

    /// @notice Node hash of the suite's TLD.
    /// @dev Computed during setup as `_tldNode()`.
    bytes32 public dotNode;

    /// @notice Deploys and wires every protocol contract used by the test suite.
    /// @dev Provisions UUPS proxies for each module, registers them under their
    ///      canonical keys on the protocol registry, and installs default
    ///      personhood mocks so tests begin at the `NoStatus` tier.
    function setUp() public virtual noGasMetering {
        vm.warp(365 days);

        ed = _createUser("ed");
        leonardo = _createUser("leonardo");
        tiago = _createUser("tiago");
        owner = _createUser("owner");

        dotLabel = LabelUtils.labelhashMemory(TLD_LABEL);
        dotNode = _tldNode();

        vm.startPrank(owner);
        // Deploy protocol registry first so every downstream proxy can bind to
        // it at init time. Populate the keys before deploying consumers whose
        // initialisers might otherwise race with the key lookups.
        address protocolRegistryAddress = Upgrades.deployUUPSProxy(
            "DotnsProtocolRegistry.sol:DotnsProtocolRegistry",
            abi.encodeCall(DotnsProtocolRegistry.initialize, (TLD_LABEL))
        );
        protocolRegistry = DotnsProtocolRegistry(protocolRegistryAddress);
        vm.label(protocolRegistryAddress, "DotnsProtocolRegistry");
        // Anchor the fixture to the deployed TLD authority: consumers read these live, so a
        // fixture whose derived node or suffix disagreed would test the wrong protocol.
        assertEq(protocolRegistry.tldNode(), dotNode);
        assertEq(protocolRegistry.tld(), string.concat(".", TLD_LABEL));
        IDotnsProtocolRegistry registry = IDotnsProtocolRegistry(protocolRegistryAddress);

        storeFactory = new StoreFactory(protocolRegistryAddress, owner);
        vm.label(address(storeFactory), "StoreFactory");

        address dotnsRegistrarAddress = Upgrades.deployUUPSProxy(
            "DotnsRegistrar.sol:DotnsRegistrar",
            abi.encodeCall(DotnsRegistrar.initialize, ("Dotns", "Dotns", registry))
        );
        dotnsRegistrar = DotnsRegistrar(dotnsRegistrarAddress);
        vm.label(dotnsRegistrarAddress, "DotnsRegistrar");

        address dotnsReverseResolverAddress = Upgrades.deployUUPSProxy(
            "DotnsReverseResolver.sol:DotnsReverseResolver",
            abi.encodeCall(DotnsReverseResolver.initialize, (registry))
        );
        dotnsReverseResolver = DotnsReverseResolver(dotnsReverseResolverAddress);
        vm.label(dotnsReverseResolverAddress, "DotnsReverseResolver");

        address dotnsRegistryAddress = Upgrades.deployUUPSProxy(
            "DotnsRegistry.sol:DotnsRegistry", abi.encodeCall(DotnsRegistry.initialize, (registry))
        );
        dotnsRegistry = DotnsRegistry(dotnsRegistryAddress);
        vm.label(dotnsRegistryAddress, "DotnsRegistry");

        address dotnsContentResolverAddress = Upgrades.deployUUPSProxy(
            "DotnsContentResolver.sol:DotnsContentResolver",
            abi.encodeCall(DotnsContentResolver.initialize, (registry))
        );
        dotnsContentResolver = DotnsContentResolver(dotnsContentResolverAddress);
        vm.label(dotnsContentResolverAddress, "DotnsContentResolver");

        flatPricing = new DotnsFlatPricing(BASE_DEPOSIT);
        vm.label(address(flatPricing), "DotnsFlatPricing");
        scarcityPricing = new DotnsScarcityPricing(BASE_DEPOSIT, MIN_PRICE);
        vm.label(address(scarcityPricing), "DotnsScarcityPricing");
        costModelRegistry = new DotnsCostModelRegistry(owner);
        vm.label(address(costModelRegistry), "DotnsCostModelRegistry");
        costModelRegistry.register(IDotnsPricing(address(flatPricing)));

        address popRulesAddress = Upgrades.deployUUPSProxy(
            "PopRules.sol:PopRules", abi.encodeCall(PopRules.initialize, (registry))
        );
        popRules = PopRules(popRulesAddress);
        vm.label(popRulesAddress, "PopRules");
        // Open the short-name market so the band and registration suites exercise names below nine
        // characters. Toggled as a Root origin because the setter is Root-gated. The default-closed
        // state is covered directly in PopRules unit tests.
        _setShortNames(true);

        address dotnsResolverAddress = Upgrades.deployUUPSProxy(
            "DotnsResolver.sol:DotnsResolver", abi.encodeCall(DotnsResolver.initialize, (registry))
        );
        dotnsResolver = DotnsResolver(dotnsResolverAddress);
        vm.label(dotnsResolverAddress, "DotnsResolver");

        address dotnsRegistrarControllerAddress = Upgrades.deployUUPSProxy(
            "DotnsRegistrarController.sol:DotnsRegistrarController",
            abi.encodeCall(DotnsRegistrarController.initialize, (registry, 6 seconds, 1 days))
        );
        dotnsRegistrarController = DotnsRegistrarController(dotnsRegistrarControllerAddress);
        vm.label(dotnsRegistrarControllerAddress, "DotnsRegistrarController");

        dotnsRegistrar.addController(IDotnsController(dotnsRegistrarControllerAddress));

        address dotnsPopResolverAddress = Upgrades.deployUUPSProxy(
            "DotnsPopResolver.sol:DotnsPopResolver",
            abi.encodeCall(DotnsPopResolver.initialize, (registry))
        );
        dotnsPopResolver = DotnsPopResolver(dotnsPopResolverAddress);
        vm.label(dotnsPopResolverAddress, "DotnsPopResolver");

        address dotnsPopControllerAddress = Upgrades.deployUUPSProxy(
            "DotnsPopController.sol:DotnsPopController",
            abi.encodeCall(DotnsPopController.initialize, (registry, DEFAULT_RESERVATION_DURATION))
        );
        dotnsPopController = DotnsPopController(dotnsPopControllerAddress);
        vm.label(dotnsPopControllerAddress, "DotnsPopController");

        dotnsRegistrar.addController(IDotnsController(dotnsPopControllerAddress));

        address dotnsNameEscrowAddress = Upgrades.deployUUPSProxy(
            "DotnsNameEscrow.sol:DotnsNameEscrow",
            abi.encodeCall(
                DotnsNameEscrow.initialize,
                (
                    IDotnsProtocolRegistry(protocolRegistryAddress),
                    ESCROW_COOLDOWN,
                    ESCROW_REDEEM_WINDOW
                )
            )
        );
        dotnsNameEscrow = DotnsNameEscrow(payable(dotnsNameEscrowAddress));
        vm.label(dotnsNameEscrowAddress, "DotnsNameEscrow");

        protocolRegistry.set(DotnsConstants.REGISTRAR, dotnsRegistrarAddress);
        protocolRegistry.set(DotnsConstants.CONTROLLER, dotnsRegistrarControllerAddress);
        protocolRegistry.set(DotnsConstants.REGISTRY, dotnsRegistryAddress);
        protocolRegistry.set(DotnsConstants.REVERSE_RESOLVER, dotnsReverseResolverAddress);
        protocolRegistry.set(DotnsConstants.POP_RULES, popRulesAddress);
        protocolRegistry.set(DotnsConstants.COST_MODEL, address(costModelRegistry));
        protocolRegistry.set(DotnsConstants.STORE_FACTORY, address(storeFactory));
        protocolRegistry.set(DotnsConstants.RESOLVER, dotnsResolverAddress);
        protocolRegistry.set(DotnsConstants.CONTENT_RESOLVER, dotnsContentResolverAddress);
        protocolRegistry.set(DotnsConstants.POP_RESOLVER, dotnsPopResolverAddress);
        protocolRegistry.set(DotnsConstants.POP_CONTROLLER, dotnsPopControllerAddress);
        protocolRegistry.set(DotnsConstants.NAME_ESCROW, dotnsNameEscrowAddress);
        _deployNameWhitelist();

        // Deploy the read-only lens last, once every sibling key it resolves
        // (POP_CONTROLLER, REGISTRAR, STORE_FACTORY, POP_RESOLVER, POP_RULES) is
        // set on the registry.
        dotnsPopLens = new DotnsPopLens(registry);
        vm.label(address(dotnsPopLens), "DotnsPopLens");

        vm.stopPrank();
        vm.warp(block.timestamp + 365 days);
        // Default every account to `None` (NoStatus) on the personhood
        // precompile. Per-account `_grantPopFull`/`_grantPopLite` calls install
        // more specific mocks that override this selector-only stub.
        vm.mockCall(
            DotnsConstants.PERSONHOOD,
            abi.encodeWithSelector(IPersonhood.personhoodStatus.selector),
            abi.encode(IPersonhood.PersonhoodInfo({status: 0, contextAlias: bytes32(0)}))
        );
        // Default the revive System precompile to a non-Root origin. Every governance-gated path
        // reads it (`DotnsNameWhitelist.onlyGovernance`, `DotnsRegistrarController`'s reserved
        // path), and there is no code at the precompile address under forge, so an unmocked read
        // decodes empty returndata and reverts. Tests exercising the Root branch override with
        // `_mockOriginIsRoot(true)`.
        _mockOriginIsRoot(false);
    }

    /// @notice Mocks revive's System precompile originIsRoot result.
    /// @param returnValue Value to return from `originIsRoot`.
    function _mockOriginIsRoot(bool returnValue) internal {
        vm.mockCall(
            DotnsConstants.REVIVE_SYSTEM,
            abi.encodeWithSelector(ISystem.originIsRoot.selector),
            abi.encode(returnValue)
        );
    }

    /// @notice Toggles the short-name market as a substrate Root origin.
    /// @dev `setShortNamesEnabled` is Root-gated, so mock the System precompile's `originIsRoot`
    ///      true for the call, then restore false so the default test origin stays non-Root.
    function _setShortNames(bool enabled) internal {
        _mockOriginIsRoot(true);
        popRules.setShortNamesEnabled(enabled);
        _mockOriginIsRoot(false);
    }

    /// @notice Computes the namehash of `parent` and `labelhash`.
    /// @dev Thin wrapper around @custom:function LabelUtils.namehashUnder so tests
    ///      do not reimplement the assembly composition.
    /// @param parent The parent node hash.
    /// @param labelhash The labelhash.
    /// @return node The resulting node hash.
    function _namehash(bytes32 parent, bytes32 labelhash) internal pure returns (bytes32 node) {
        node = LabelUtils.namehashUnder(parent, labelhash);
    }

    /// @notice Computes the ERC721 tokenId used by DotnsRegistrar for a given label.
    /// @dev DotnsRegistrar mints tokenId = uint256(node), where node = namehash(tldNode,
    ///      labelhash). This helper prevents tests from accidentally using uint256(node) as
    ///      the tokenId.
    /// @param label The label to compute for (without the TLD suffix).
    /// @return tokenId The ERC721 tokenId (uint256(node)).
    function _tokenIdForLabel(string memory label) internal pure returns (uint256 tokenId) {
        tokenId = uint256(_nodeOf(label));
    }

    /// @notice Node hash of the suite's TLD, derived from @custom:constant TLD_LABEL.
    /// @dev `namehash(0, keccak256(TLD_LABEL))`. Derived rather than a literal so the single
    ///      definition point drives every node; stays pure because keccak runs in a pure body.
    /// @return node The TLD node the registry is initialised with.
    function _tldNode() internal pure returns (bytes32 node) {
        node = LabelUtils.namehashUnder(ZERO_HASH, LabelUtils.labelhashMemory(TLD_LABEL));
    }

    /// @notice Computes `namehash(tldNode, keccak256(label))` for a flat label.
    /// @dev Shared across test suites that need the node identifier for a top-level label.
    /// @param label Label (without the TLD suffix).
    /// @return node The node identifier under the suite's TLD.
    function _nodeOf(string memory label) internal pure returns (bytes32 node) {
        node = LabelUtils.namehashUnder(_tldNode(), LabelUtils.labelhashMemory(label));
    }

    /// @notice Returns a valid 65-byte chat key seeded with `seed`.
    /// @dev Format mimics the uncompressed secp256k1 encoding (1 prefix byte + 32 X + 32 Y)
    ///      so the resolver's length guard is satisfied.
    function _validChatKey(bytes1 seed) internal pure returns (bytes memory key) {
        key = new bytes(65);
        key[0] = 0x04;
        for (uint256 i = 1; i < 65; i++) {
            key[i] = seed;
        }
    }

    /// @notice Mocks the personhood precompile so it returns `tier` for `who`
    ///         under the dotns context.
    /// @dev Single source of truth for tier mocking. Tier numbering matches
    ///      @custom:contract IPersonhood: 0=None, 1=Lite, 2=Full. `contextAlias` is non-zero
    ///      whenever `tier != 0` so callers that read it (cross-context
    ///      identity tests) still see a deterministic value.
    function _setUserPopStatus(address who, IPopRules.PopStatus tier) internal {
        uint8 status;
        if (tier == IPopRules.PopStatus.PopFull) status = 2;
        else if (tier == IPopRules.PopStatus.PopLite) status = 1;
        // PopStatus.Reserved is a label classification, never a user tier; map
        // anything else to None.
        bytes32 contextAlias = status == 0 ? bytes32(0) : keccak256(abi.encode(who, status));
        vm.mockCall(
            DotnsConstants.PERSONHOOD,
            abi.encodeWithSelector(
                IPersonhood.personhoodStatus.selector, who, DotnsConstants.PERSONHOOD_CONTEXT
            ),
            abi.encode(IPersonhood.PersonhoodInfo({status: status, contextAlias: contextAlias}))
        );
    }

    /// @notice Grants PopFull status to `who` via the personhood precompile mock.
    function _grantPopFull(address who) internal {
        _setUserPopStatus(who, IPopRules.PopStatus.PopFull);
    }

    /// @notice Grants PopLite status to `who` via the personhood precompile mock.
    function _grantPopLite(address who) internal {
        _setUserPopStatus(who, IPopRules.PopStatus.PopLite);
    }

    /// @notice Resets `who` back to `None` on the personhood precompile mock.
    function _grantNoStatus(address who) internal {
        _setUserPopStatus(who, IPopRules.PopStatus.NoStatus);
    }

    /// @notice Deploys the name whitelist and registers it under `NAME_WHITELIST`.
    /// @dev Its own function, taking no arguments and reading `protocolRegistry` from storage,
    ///      because `setUp` is at the stack limit under via-ir: extending the live range of one
    ///      more local there fails to compile.
    function _deployNameWhitelist() private {
        dotnsNameWhitelist = DotnsNameWhitelist(
            Upgrades.deployUUPSProxy(
                "DotnsNameWhitelist.sol:DotnsNameWhitelist",
                abi.encodeCall(DotnsNameWhitelist.initialize, (protocolRegistry))
            )
        );
        vm.label(address(dotnsNameWhitelist), "DotnsNameWhitelist");
        protocolRegistry.set(DotnsConstants.NAME_WHITELIST, address(dotnsNameWhitelist));
    }

    /// @notice Grants `label` to `user` on the name whitelist under a mocked Root origin.
    /// @dev The whitelist's admin surface is Root-only, so this mocks `originIsRoot` for the call
    ///      and restores the default afterwards. The reserved registration path requires a grant
    ///      naming the intended owner, so this is the setup step every `registerReserved` test
    ///      needs. Restoring matters: `registerReserved` reads `originIsRoot` too, and a sticky
    ///      `true` would put the registration itself on the Root branch.
    function _grantName(string memory label, address user) internal {
        _mockOriginIsRoot(true);
        dotnsNameWhitelist.grantName(label, user);
        _mockOriginIsRoot(false);
    }

    /// @notice Drives a PoP reservation under a Root origin and settles the resulting
    /// pending claim from the user's signed origin.
    /// @dev Single canonical helper for PoP-gateway reservations across unit and fuzz
    /// test suites. Calls the controller under a mocked Root origin.
    /// The auto-settle deploys the user's `LabelStore` and writes the stashed label so
    /// subsequent gateway mints for the same user take the warm path and assertions
    /// against the resolver and store hold. Chat keys are persisted eagerly on the PoP
    /// resolver at reserve time regardless of settlement. Tests that want to observe
    /// cold-path semantics (label stashed, no store deployed) must call
    /// @custom:function _rootReserveBaseName or @custom:function _rootReserveLiteName
    /// directly.
    function _reservePop(
        address user,
        string memory liteLabel,
        bytes memory chatKey,
        string memory reservedBaseLabel
    )
        internal
    {
        _rootReserveBaseName(
            IDotnsPopController.BaseReservation({
                lite: IDotnsPopController.LiteRegistration({
                    liteLabel: liteLabel, user: user, chatKey: chatKey
                }),
                reservedBaseLabel: reservedBaseLabel
            })
        );
        if (dotnsPopController.pendingClaimCountOf(user) != 0) {
            vm.prank(user);
            dotnsPopController.settlePendingClaims(user, type(uint256).max);
        }
    }

    /// @notice Dispatches the typed `reserveLiteName` call under a mocked Root origin.
    function _rootReserveLiteName(IDotnsPopController.LiteRegistration memory params) internal {
        _dispatchFromRoot(abi.encodeWithSelector(SELECTOR_RESERVE_LITE_TYPED, params));
    }

    /// @notice Dispatches the typed `reserveBaseName` call under a mocked Root origin.
    function _rootReserveBaseName(IDotnsPopController.BaseReservation memory params) internal {
        _dispatchFromRoot(abi.encodeWithSelector(SELECTOR_RESERVE_BASE_TYPED, params));
    }

    /// @notice Dispatches the typed `reserveBaseNameOnly` call under a mocked Root origin.
    function _rootReserveBaseNameOnly(IDotnsPopController.BaseNameReservation memory params)
        internal
    {
        _dispatchFromRoot(abi.encodeWithSelector(SELECTOR_RESERVE_BASE_ONLY_TYPED, params));
    }

    /// @notice Dispatches the typed `registerBaseName` call under a mocked Root origin.
    /// @dev Dispatches the label as written. The gateway sends what People Chain holds, so a
    ///      helper that reshaped it would hide whether a fixture is a valid lite label.
    function _rootRegisterBaseName(IDotnsPopController.FullRegistration memory params) internal {
        _dispatchFromRoot(abi.encodeWithSelector(SELECTOR_REGISTER_BASE_TYPED, params));
    }

    /// @notice Calls `payload` on the PoP controller under a mocked Root origin.
    /// @dev Reverts with the inner error data when the call fails, so
    ///      `vm.expectRevert` assertions remain meaningful at the test level.
    function _dispatchFromRoot(bytes memory payload) internal returns (bytes memory ret) {
        _mockOriginIsRoot(true);

        (bool ok, bytes memory data) = address(dotnsPopController).call(payload);
        // Restore the default before unwinding, on both the success and revert paths.
        // `DotnsRegistrarController.registerReserved` reads `originIsRoot` too, so a sticky
        // `true` here would silently put a later reserved registration on the Root branch,
        // skipping the grant check and the consume.
        _mockOriginIsRoot(false);
        if (!ok) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }

        return data;
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

    /// @notice Submits a commitment, waits for the minimum age, then registers with the exact
    ///         oracle price.
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

    /// @notice Minimal commit-reveal helper aligned to IDotnsRegistrarController.
    /// @param label Label to register.
    /// @param nameOwner Address to assign as owner.
    /// @param reserveName Whether the name is reserved.
    function _commitAndRegister(string memory label, address nameOwner, bool reserveName) internal {
        bytes32 secret = keccak256(abi.encodePacked(label, nameOwner, block.timestamp));

        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label,
                owner: nameOwner,
                secret: secret,
                reserved: reserveName,
                maxPrice: type(uint256).max,
                pricingVersion: popRules.pricingVersion()
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

    /// @notice Registers `label` for `labelOwner` under the requested PoP status and
    ///         returns its node.
    /// @dev For NoStatus, no status is set on the oracle. For PopLite/PopFull, status is set
    ///      for `(labelOwner, label)` before commit-reveal.
    /// @param label The label to register (without the `.dot` suffix).
    /// @param labelOwner The address that will own the registered label.
    /// @param status The PoP status to set for this label (NoStatus skips setting).
    /// @return node The node identifier for `<label>.dot`.
    function _register(
        string memory label,
        address labelOwner,
        IPopRules.PopStatus status
    )
        internal
        returns (bytes32 node)
    {
        if (status != IPopRules.PopStatus.NoStatus) {
            _setUserPopStatus(labelOwner, status);
        }

        _commitAndRegister(label, labelOwner, true);

        node = _nodeOf(label);
    }

    /// @notice Checks whether a string array contains a given string.
    /// @dev Compares by keccak256(bytes(string)) to avoid costly byte-by-byte comparisons.
    /// @param array The array to search.
    /// @param needle The string to find.
    /// @return found True if `needle` is present in `array`.
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
