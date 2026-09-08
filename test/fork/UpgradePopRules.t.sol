// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {PopRules} from "../../contracts/pop/PopRules.sol";
import {IPopRules} from "../../contracts/pop/IPopRules.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {IPersonhood} from "../../contracts/external/personhood/IPersonhood.sol";
import {ISystem} from "../../contracts/external/revive/ISystem.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {UpgradePopRules} from "../../scripts/deploy/UpgradePopRules.s.sol";

/// @title UpgradePopRulesHarness
/// @notice Exposes the upgrade script's internal upgrade path so the fork test drives the exact
///         code the production run executes, including the fail-closed storage-layout diff.
/// @dev Mirrors the registrar harness pattern: forward to the script internal rather than
///      re-implement the upgrade, so the test tracks the production path one-to-one.
contract UpgradePopRulesHarness is UpgradePopRules {
    /// @notice Upgrades `proxy` under `owner` through the script's `_upgradePopRules`.
    function upgradePopRules(address owner, address proxy) external {
        _upgradePopRules(owner, proxy);
    }
}

/// @title UpgradePopRulesForkTest
/// @notice Pairs one-to-one with `scripts/deploy/UpgradePopRules.s.sol`. Forks the live Paseo Asset
///         Hub through the ETH-RPC adapter, upgrades the deployed PopRules proxy with the script,
///         and re-runs the oracle's P0 paths against real on-chain state. Proves the swap keeps the
///         proxy, its owner, and the registry pointer, keeps classification and pricing reads
///         answering, and keeps the Root-gated short-name lever working.
/// @dev PR-scoped: deleted before merge with the upgrade script and the `PopRulesOld` snapshot.
///      Requires the local adapter on `paseo_local`; between upgrade PRs `test/fork/` is empty, so
///      the suite is skipped by default with `--no-match-path 'test/fork/**'`.
/// @custom:security-contact admin@parity.io
contract UpgradePopRulesForkTest is Test {
    /// @notice Manifest recording the live deployment addresses this fork resolves against.
    string internal constant MANIFEST_PATH = "deployments/paseo-assethub/420420417.json";

    /// @notice A plain nine-character label priced and classified as open to every caller.
    string internal constant OPEN_LABEL = "alicexyzz";

    /// @notice A plain six-character label that sits in the governed short-name band.
    string internal constant SHORT_LABEL = "aliced";

    /// @notice Drives the script's upgrade path against the live proxy.
    UpgradePopRulesHarness internal upgrader;

    /// @notice The deployed PopRules proxy under upgrade.
    PopRules internal popRules;

    /// @notice The deployed protocol registry the oracle resolves siblings through.
    IDotnsProtocolRegistry internal protocolRegistry;

    /// @notice Proxy owner, impersonated to authorise the upgrade.
    address internal popRulesOwner;

    /// @notice An unverified account used for the pricing preview reads.
    address internal user;

    /// @notice Forks Paseo and resolves the live PopRules proxy, its owner, and the registry.
    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("paseo_local"));

        string memory manifest = vm.readFile(MANIFEST_PATH);
        popRules = PopRules(vm.parseJsonAddress(manifest, ".PopRules"));
        protocolRegistry =
            IDotnsProtocolRegistry(vm.parseJsonAddress(manifest, ".DotnsProtocolRegistry"));
        popRulesOwner = OwnableUpgradeable(address(popRules)).owner();

        upgrader = new UpgradePopRulesHarness();

        user = makeAddr("user");
    }

    /// @notice Mocks the personhood precompile so every account reads as unverified, keeping the
    ///         pricing preview deterministic on any fork state.
    function _mockNoPersonhood() internal {
        vm.mockCall(
            DotnsConstants.PERSONHOOD,
            abi.encodeWithSelector(IPersonhood.personhoodStatus.selector),
            abi.encode(IPersonhood.PersonhoodInfo({status: 0, contextAlias: bytes32(0)}))
        );
    }

    /// @notice The upgrade keeps the proxy, the registry pointer, and the classification and
    ///         pricing reads intact, and installs the Root gate on the short-name lever.
    function test_upgrade_preservesStateAndKeepsPricingWorking() public {
        // Seed representative reads on the pre-upgrade implementation.
        address registryBefore = address(popRules.protocolRegistry());
        uint256 priceBefore = popRules.price(OPEN_LABEL);
        (IPopRules.PopStatus statusBefore, string memory messageBefore) =
            popRules.classifyName(OPEN_LABEL);

        address proxy = address(popRules);
        upgrader.upgradePopRules(popRulesOwner, proxy);

        assertEq(address(popRules), proxy, "upgrade keeps the same proxy address");
        assertEq(
            address(popRules.protocolRegistry()),
            registryBefore,
            "post-upgrade: protocol registry pointer preserved"
        );

        // P0: pricing and classification still answer sensibly, unchanged for a plain open label.
        assertEq(popRules.price(OPEN_LABEL), priceBefore, "post-upgrade: price preserved");
        (IPopRules.PopStatus statusAfter, string memory messageAfter) =
            popRules.classifyName(OPEN_LABEL);
        assertEq(
            uint256(statusAfter), uint256(statusBefore), "post-upgrade: classification preserved"
        );
        assertEq(uint256(statusAfter), uint256(IPopRules.PopStatus.NoStatus), "open label is open");
        assertEq(messageAfter, messageBefore, "post-upgrade: classification message preserved");

        // New surface: the short-name lever is now gated on a Root origin. A non-Root origin
        // reverts with the typed error rather than the pre-upgrade owner gate.
        vm.mockCall(
            DotnsConstants.REVIVE_SYSTEM,
            abi.encodeWithSelector(ISystem.originIsRoot.selector),
            abi.encode(false)
        );
        vm.prank(popRulesOwner);
        vm.expectRevert(IPopRules.NotRoot.selector);
        popRules.setShortNamesEnabled(true);
    }

    /// @notice After the upgrade, a Root origin opens the short-name market and the public pricing
    ///         preview transitions from reverting to returning for a short label.
    function test_upgrade_rootOpensShortNameMarket() public {
        upgrader.upgradePopRules(popRulesOwner, address(popRules));
        _mockNoPersonhood();

        // Closed by default: the public preview rejects a short label.
        assertFalse(popRules.shortNamesEnabled(), "short names closed after upgrade");
        vm.expectRevert(
            abi.encodeWithSelector(IPopRules.PopError.selector, "Short names are not for sale")
        );
        popRules.priceWithoutCheck(SHORT_LABEL, user);

        // A Root origin flips the lever.
        vm.mockCall(
            DotnsConstants.REVIVE_SYSTEM,
            abi.encodeWithSelector(ISystem.originIsRoot.selector),
            abi.encode(true)
        );
        vm.prank(user);
        popRules.setShortNamesEnabled(true);
        assertTrue(popRules.shortNamesEnabled(), "Root opened the short-name market");

        // P0: the public preview now returns a price for the same short label.
        IPopRules.PriceWithMeta memory metadata = popRules.priceWithoutCheck(SHORT_LABEL, user);
        assertEq(popRules.price(SHORT_LABEL), metadata.price, "preview price matches the curve");
    }
}
