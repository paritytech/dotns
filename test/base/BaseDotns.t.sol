// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {PopRules, IPopRules} from "../../contracts/pop/PopRules.sol";
import {DotnsRegistrar, IDotnsRegistrar} from "../../contracts/registrars/DotnsRegistrar.sol";
import {
    DotnsRegistrarController,
    IDotnsRegistrarController
} from "../../contracts/registrars/DotnsRegistrarController.sol";
import {DotnsRegistry, IDotnsRegistry} from "../../contracts/registry/DotnsRegistry.sol";
import {DotnsResolver} from "../../contracts/resolvers/DotnsResolver.sol";
import {DotnsContentResolver} from "../../contracts/resolvers/DotnsContentResolver.sol";
import {
    DotnsReverseResolver,
    IDotnsReverseResolver
} from "../../contracts/resolvers/DotnsReverseResolver.sol";
import {Store} from "../../contracts/store/Store.sol";
import {StoreFactory, IStoreFactory} from "../../contracts/store/StoreFactory.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IPersonhood} from "../../contracts/pop/IPersonhood.sol";

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
abstract contract BaseDotns is Test {
    /// @notice Genesis PopFull account
    address internal constant ADDR_POP_FULL = 0x1111111111111111111111111111111111111111;

    /// @notice Genesis PopLite account
    address internal constant ADDR_POP_LITE = 0x2222222222222222222222222222222222222222;

    /// @notice Genesis Demoted account
    address internal constant ADDR_DEMOTED = 0x3333333333333333333333333333333333333333;

    address public ed;
    address public leonardo;
    address public tiago;
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

    /// @notice Deployed Store factory instance.
    StoreFactory public storeFactory;

    /// @notice Rent price applied to PoP NoStatus users for spam resistance.
    /// @dev This value is passed into PopRules initialization in this base test.
    uint256 public constant RENT_PRICE = 2e15 wei;

    /// @notice Zero hash constant
    bytes32 public constant ZERO_HASH = bytes32(0);

    /// @notice Label hash for "dot".
    /// @dev Computed during setup as `keccak256(bytes("dot"))`.
    bytes32 public dotLabel;

    /// @notice Node hash for the ".dot" TLD.
    /// @dev Computed during setup as `_namehash(ZERO_HASH, dotLabel)`.
    bytes32 public dotNode;

    /// @notice Default node hash for the ".dot" TLD.
    /// @dev Included to cross-check against computed `dotNode` where relevant.
    bytes32 private constant DOT_NODE =
        0x3fce7d1364a893e213bc4212792b517ffc88f5b13b86c8ef9c8d390c3a1370ce;

    /// @notice Precompile address for the on-chain Personhood status oracle.
    address internal constant PERSONHOOD_PRECOMPILE = 0x000000000000000000000000000000000a010000;

    /// @notice Fork identifier for the local People chain node.
    uint256 public forkId;

    function setUp() public virtual noGasMetering {
        forkId = vm.createSelectFork("paseo_local");
        _bridgePersonhoodPrecompile();

        vm.warp(365 days);

        ed = _createUser("ed");
        leonardo = _createUser("leonardo");
        tiago = _createUser("tiago");
        owner = _createUser("owner");

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

        dotnsReverseResolver.updateRegistrar(
            IDotnsRegistrarController(dotnsRegistrarControllerAddress)
        );
        popRules.updateDotRegistry(dotnsRegistrarControllerAddress);
        dotnsRegistrar.addController(IDotnsRegistrarController(dotnsRegistrarControllerAddress));
        dotnsRegistry.updateRegistrarController(
            IDotnsRegistrarController(dotnsRegistrarControllerAddress)
        );

        vm.stopPrank();

        vm.label(PERSONHOOD_PRECOMPILE, "PersonhoodPrecompile");

        vm.warp(block.timestamp + 365 days);
    }

    /// @notice Seeds `vm.mockCall` entries for the Personhood precompile.
    /// @dev The native precompile at 0x0A010000 is unreachable from Forge's EVM.
    ///      Genesis accounts mirror the People chain state; catch-all returns NoStatus.
    function _bridgePersonhoodPrecompile() internal {
        vm.mockCall(
            PERSONHOOD_PRECOMPILE,
            abi.encodeCall(IPersonhood.personhoodStatus, (ADDR_POP_FULL)),
            abi.encode(uint8(2))
        );
        vm.mockCall(
            PERSONHOOD_PRECOMPILE,
            abi.encodeCall(IPersonhood.personhoodStatus, (ADDR_POP_LITE)),
            abi.encode(uint8(1))
        );
        vm.mockCall(
            PERSONHOOD_PRECOMPILE,
            abi.encodeCall(IPersonhood.personhoodStatus, (ADDR_DEMOTED)),
            abi.encode(uint8(3))
        );
        vm.mockCall(
            PERSONHOOD_PRECOMPILE,
            abi.encodeWithSelector(IPersonhood.personhoodStatus.selector),
            abi.encode(uint8(0))
        );
    }

    /// @notice Overrides the precompile mock for a specific account.
    /// @param account The address whose personhood status to set.
    /// @param status The desired PoP tier.
    function _setPersonhoodStatus(address account, IPopRules.PopStatus status) internal {
        uint8 raw;
        if (status == IPopRules.PopStatus.PopFull) raw = 2;
        else if (status == IPopRules.PopStatus.PopLite) raw = 1;
        // NoStatus maps to raw 0 (default)

        vm.mockCall(
            PERSONHOOD_PRECOMPILE,
            abi.encodeCall(IPersonhood.personhoodStatus, (account)),
            abi.encode(raw)
        );
    }

    /// @notice Computes an namehash for `parent` and `label`.
    /// @dev Equivalent to `keccak256(abi.encodePacked(parent, label))`.
    /// @param parent The parent node hash.
    /// @param label The label hash.
    /// @return node The resulting node hash.
    function _namehash(bytes32 parent, bytes32 label) internal pure returns (bytes32 node) {
        node = keccak256(abi.encodePacked(parent, label));
    }

    /// @notice Computes the ERC721 tokenId used by DotnsRegistrar for a given label.
    /// @dev DotnsRegistrar mints tokenId = uint256(node), where node = namehash(DOT_NODE, labelhash).
    ///      This helper prevents tests from accidentally using uint256(node) as the tokenId.
    /// @param label The label to compute for (without the `.dot` suffix).
    /// @return tokenId The ERC721 tokenId (uint256(node)).
    function _tokenIdForLabel(string memory label) internal pure returns (uint256 tokenId) {
        bytes32 labelhash = keccak256(bytes(label));
        bytes32 node = keccak256(abi.encodePacked(DOT_NODE, labelhash));
        tokenId = uint256(node);
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

    /// @notice Asserts the precompile returns the expected PoP tier for `account`.
    /// @param account The address to query.
    /// @param status The expected PoP tier.
    function _assertPersonhoodStatus(address account, IPopRules.PopStatus status) internal view {
        uint8 raw;
        if (status == IPopRules.PopStatus.PopFull) raw = 2;
        else if (status == IPopRules.PopStatus.PopLite) raw = 1;
        // NoStatus and Reserved both map to raw 0

        uint8 actual = IPersonhood(PERSONHOOD_PRECOMPILE).personhoodStatus(account);
        assertEq(actual, raw, "Personhood status mismatch");
    }

    /// @notice Registers `label` for `labelOwner` under the requested PoP status and returns its node.
    /// @dev For NoStatus, the default precompile state (returns 0) is used.
    ///      For PopLite/PopFull, the precompile status is set before commit–reveal.
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
            _setPersonhoodStatus(labelOwner, status);
        }

        _commitAndRegister(label, labelOwner, true);

        // IMPORTANT: tokenId is uint256(node) where node = namehash(DOT_NODE, labelhash)
        // Do not use uint256(node) as the tokenId in tests.
        node = keccak256(abi.encodePacked(DOT_NODE, keccak256(bytes(label))));
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

    /// @notice Computes keccak256("dotns.registered", labelhash)
    /// @param labelhash keccak256(label).
    /// @return key Store key used for DotNS-written registration entry.
    function _storeKey(bytes32 labelhash) internal pure returns (bytes32 key) {
        assembly {
            let pointer := mload(0x40)
            mstore(pointer, 0x646f746e732e7265676973746572656400000000000000000000000000000000)
            mstore(add(pointer, 0x20), labelhash)
            key := keccak256(pointer, 0x40)
        }
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
