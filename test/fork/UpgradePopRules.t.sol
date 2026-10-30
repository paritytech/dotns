// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BasePopFork} from "./BasePopFork.t.sol";
import {UpgradePopRules} from "../../scripts/deploy/UpgradePopRules.s.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPopRules} from "../../contracts/pop/IPopRules.sol";

/// @title UpgradePopRulesHarness
/// @notice Exposes the upgrade script's internal path so the test drives the code the production
///         run executes, including the fail-closed storage-layout diff.
/// @dev Forwarding to the script internal keeps the test honest: a test that called
///      `Upgrades.upgradeProxy` itself would keep passing after the script stopped doing the same
///      thing.
contract UpgradePopRulesHarness is UpgradePopRules {
    /// @notice Upgrades `proxy` under `owner` through the script's own internal.
    function upgrade(address owner, address proxy) external {
        _upgradePopRules(owner, proxy);
    }
}

/// @title UpgradePopRulesForkTest
/// @notice Pairs one-to-one with `scripts/deploy/UpgradePopRules.s.sol`. Upgrades the deployed
///         rules and proves classification and pricing survive the swap, and that the PoP
///         controller still deployed keeps issuing against the new rules.
/// @dev Requires the local ETH-RPC adapter on `paseo_local`, or `PASEO_FORK_RPC`; see
///      `DEPLOYMENTS.md`. Run the suite with `bun run test:fork`.
/// @custom:security-contact admin@parity.io
contract UpgradePopRulesForkTest is BasePopFork {
    /// @notice The deployed proxy under upgrade.
    address internal proxy;

    /// @notice Proxy owner, the broadcaster the script requires.
    address internal proxyOwner;

    /// @notice Drives the script's upgrade path against the live proxy.
    UpgradePopRulesHarness internal upgrader;

    function setUp() public override {
        super.setUp();
        proxy = _live("PopRules");
        proxyOwner = _ownerOf(proxy);
        upgrader = new UpgradePopRulesHarness();
    }

    /// @notice The swap lands, reports the new interface, and leaves pricing and classification
    ///         as they were.
    function test_upgrade_preserves_pricing_and_classification() public {
        IPopRules rules = IPopRules(proxy);
        address implementationBefore = _implementationOf(proxy);
        uint256 versionBefore = rules.pricingVersion();
        uint256 priceBefore = rules.price("forkpricingprobe");
        (IPopRules.PopStatus shortBefore,) = rules.classifyName("abcde");
        (IPopRules.PopStatus deviceBefore,) = rules.classifyName("abcdef.07");
        (IPopRules.PopStatus openBefore,) = rules.classifyName("abcdefghi");

        upgrader.upgrade(proxyOwner, proxy);

        assertTrue(_implementationOf(proxy) != implementationBefore, "the implementation changed");
        assertTrue(
            IERC165(proxy).supportsInterface(type(IPopRules).interfaceId),
            "reports the interface the new controller requires"
        );
        assertEq(_ownerOf(proxy), proxyOwner, "owner preserved");
        assertEq(rules.pricingVersion(), versionBefore, "pricing version preserved");
        assertEq(rules.price("forkpricingprobe"), priceBefore, "price unchanged");
        (IPopRules.PopStatus shortAfter,) = rules.classifyName("abcde");
        (IPopRules.PopStatus deviceAfter,) = rules.classifyName("abcdef.07");
        (IPopRules.PopStatus openAfter,) = rules.classifyName("abcdefghi");
        assertEq(uint8(shortAfter), uint8(shortBefore), "short name class unchanged");
        assertEq(uint8(deviceAfter), uint8(deviceBefore), "device name class unchanged");
        assertEq(uint8(openAfter), uint8(openBefore), "open name class unchanged");
    }

    /// @notice Between this step and the controller's, the deployed controller still issues a
    ///         linked device and personhood pair against the upgraded rules.
    function test_deployed_controller_still_issues_after_the_swap() public {
        upgrader.upgrade(proxyOwner, proxy);

        bytes32 personhoodNode = _issueLinkedPair(_live("DotnsPopController"));

        (bool ok, bytes memory data) = _live("DotnsRegistry")
            .staticcall(abi.encodeWithSignature("owner(bytes32)", personhoodNode));
        assertTrue(ok, "registry readable");
        assertEq(abi.decode(data, (address)), popUser, "issued through the deployed controller");
    }
}
