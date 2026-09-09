// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {DotnsRegistrar} from "../../contracts/registrars/DotnsRegistrar.sol";
import {IDotnsRegistrar} from "../../contracts/registrars/IDotnsRegistrar.sol";
import {IDotnsController} from "../../contracts/registrars/IDotnsController.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {IPersonhood} from "../../contracts/external/personhood/IPersonhood.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {UpgradeRegistrar} from "../../scripts/deploy/UpgradeRegistrar.s.sol";

/// @title UpgradeRegistrarHarness
/// @notice Exposes the upgrade script's internal upgrade path so the fork test drives the exact
///         code the production run executes, including the fail-closed storage-layout diff.
/// @dev Mirrors the `DeterministicDeploymentHarness` pattern: forward to the script internal
///      rather than re-implement the upgrade, so the test tracks the production path one-to-one.
contract UpgradeRegistrarHarness is UpgradeRegistrar {
    /// @notice Upgrades `proxy` under `owner` through the script's `_upgradeRegistrar`.
    function upgradeRegistrar(address owner, address proxy) external {
        _upgradeRegistrar(owner, proxy);
    }
}

/// @title UpgradeRegistrarForkTest
/// @notice Pairs one-to-one with `scripts/deploy/UpgradeRegistrar.s.sol`. Forks the live Paseo
///         Asset Hub through the ETH-RPC adapter, upgrades the deployed registrar proxy with the
///         script, and re-runs the registrar's P0 paths against real on-chain state to prove the
///         swap preserves ownership and keeps registration, transfer, and soulbound gating working.
/// @dev PR-scoped: deleted before merge with the upgrade script and the `DotnsRegistrarOld`
///      snapshot. Requires the local adapter on `paseo_local`; between upgrade PRs `test/fork/` is
///      empty, so the suite is skipped by default with `--no-match-path 'test/fork/**'`.
/// @custom:security-contact admin@parity.io
contract UpgradeRegistrarForkTest is Test {
    /// @notice Manifest recording the live deployment addresses this fork resolves against.
    string internal constant MANIFEST_PATH = "deployments/paseo-assethub/420420417.json";

    /// @notice Drives the script's upgrade path against the live proxy.
    UpgradeRegistrarHarness internal upgrader;

    /// @notice The deployed registrar proxy under upgrade.
    DotnsRegistrar internal registrar;

    /// @notice The deployed protocol registry the registrar resolves siblings through.
    IDotnsProtocolRegistry internal protocolRegistry;

    /// @notice Proxy owner, impersonated to authorise the upgrade and controller writes.
    address internal registrarOwner;

    /// @notice The deployed commit-reveal controller, impersonated to mint public names.
    address internal registrarController;

    /// @notice The deployed PoP controller, impersonated to mint soulbound names.
    address internal popController;

    /// @notice A single label whose base length lands in the PoP-gated band, so its transfer floor
    ///         is the real `BASE_DEPOSIT` rather than zero.
    /// @dev Eight lowercase letters classify as a `PopFull` name that an unverified recipient
    ///      cannot reach, so `quoteTransferFee` prices the move at the name's own deposit.
    string internal constant SEED_LABEL = "seedname";

    /// @notice A second PoP-gated single label minted after the upgrade to prove real registration
    ///         still writes a label through the store factory.
    string internal constant POST_LABEL = "postname";

    /// @notice Recipient accounts for the transfer paths.
    address internal alice;
    address internal bob;

    /// @notice Forks Paseo, resolves the live addresses, and funds the transfer recipients.
    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("paseo_local"));

        string memory manifest = vm.readFile(MANIFEST_PATH);
        registrar = DotnsRegistrar(vm.parseJsonAddress(manifest, ".DotnsRegistrar"));
        protocolRegistry =
            IDotnsProtocolRegistry(vm.parseJsonAddress(manifest, ".DotnsProtocolRegistry"));
        registrarController = vm.parseJsonAddress(manifest, ".DotnsRegistrarController");
        popController = vm.parseJsonAddress(manifest, ".DotnsPopController");
        registrarOwner = OwnableUpgradeable(address(registrar)).owner();

        upgrader = new UpgradeRegistrarHarness();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        // The mint paths run through the live controller set rather than a freshly added one, so
        // the test reads the wiring the deployment left in place instead of masking it. The upgrade
        // assertions below prove that wiring survives the implementation swap.
    }

    /// @notice Mocks the personhood precompile so every account reads as unverified.
    /// @dev The substrate personhood precompile carries no bytecode on the EVM fork, so a
    ///      transfer-floor read reverts against live state. Pinning both parties to `NoStatus`
    ///      keeps the fee math real: a `PopFull` name an unverified recipient cannot reach prices
    ///      the move at the name's own deposit.
    function _mockNoPersonhood() internal {
        vm.mockCall(
            DotnsConstants.PERSONHOOD,
            abi.encodeWithSelector(IPersonhood.personhoodStatus.selector),
            abi.encode(IPersonhood.PersonhoodInfo({status: 0, contextAlias: bytes32(0)}))
        );
    }

    /// @notice The upgrade preserves ownership state on the real proxy and keeps minting and
    ///         transferring public names working.
    function test_upgrade_preservesStateAndKeepsCoreP0Working() public {
        uint256 seedToken = uint256(keccak256("dotns.fork.upgrade.seed"));

        // The seed mint proves the live registrar already accepts its commit-reveal controller, so
        // the test reads the deployment's wiring rather than a controller it added itself.
        assertTrue(
            registrar.controllers(IDotnsController(registrarController)),
            "pre-upgrade: the live registrar controller is wired"
        );

        // Seed ownership on the pre-upgrade implementation with a real single label, so `register`
        // writes the owner's label through the store factory and the token carries a real name.
        vm.prank(registrarController);
        registrar.register(seedToken, alice, SEED_LABEL);
        assertEq(registrar.ownerOf(seedToken), alice, "pre-upgrade: alice owns the seed name");
        assertEq(
            registrar.labelOf(seedToken), SEED_LABEL, "pre-upgrade: the seed carries its label"
        );

        address proxy = address(registrar);
        address registryBefore = address(registrar.protocolRegistry());

        upgrader.upgradeRegistrar(registrarOwner, proxy);

        assertEq(address(registrar), proxy, "upgrade keeps the same proxy address");
        assertEq(registrar.ownerOf(seedToken), alice, "post-upgrade: ownership preserved");
        assertEq(
            registrar.labelOf(seedToken), SEED_LABEL, "post-upgrade: the seed label is preserved"
        );
        assertEq(
            address(registrar.protocolRegistry()),
            registryBefore,
            "post-upgrade: protocol registry pointer preserved"
        );
        assertFalse(
            registrar.isSoulbound(seedToken),
            "post-upgrade: a name minted before the upgrade is not soulbound"
        );

        // The upgrade preserves the `controllers` mapping: both live controllers stay authorised
        // across the implementation swap without the test re-adding either.
        assertTrue(
            registrar.controllers(IDotnsController(registrarController)),
            "post-upgrade: the registrar controller mapping survives the swap"
        );
        assertTrue(
            registrar.controllers(IDotnsController(popController)),
            "post-upgrade: the PoP controller mapping survives the swap"
        );

        // P0: minting a real single label still works on the upgraded implementation, so the store
        // write path runs post-swap.
        uint256 postToken = uint256(keccak256("dotns.fork.upgrade.post"));
        vm.prank(registrarController);
        registrar.register(postToken, bob, POST_LABEL);
        assertEq(registrar.ownerOf(postToken), bob, "post-upgrade: registration still mints");
        assertEq(
            registrar.labelOf(postToken), POST_LABEL, "post-upgrade: the mint carries its label"
        );

        // P0: a public name is still transferable through the transfer-floor path. The PoP-gated
        // seed prices a move to an unverified recipient at its own deposit, so the sender pays a
        // real fee and the escrow settles it rather than taking the zero-fee early return.
        _mockNoPersonhood();
        uint256 fee = registrar.quoteTransferFee(seedToken, bob);
        assertGt(fee, 0, "post-upgrade: a PoP-gated name quotes a real transfer fee");
        vm.prank(alice);
        registrar.transferFrom{value: fee}(alice, bob, seedToken);
        assertEq(registrar.ownerOf(seedToken), bob, "post-upgrade: a public name still transfers");
        assertEq(
            registrar.labelOf(seedToken), SEED_LABEL, "post-upgrade: the label follows the transfer"
        );
    }

    /// @notice After the upgrade, a name minted through the PoP controller is soulbound and every
    ///         transfer path reverts.
    function test_upgrade_enablesSoulboundGatingForGatewayMints() public {
        upgrader.upgradeRegistrar(registrarOwner, address(registrar));

        // The PoP controller mints through the live wiring the upgrade preserved.
        assertTrue(
            registrar.controllers(IDotnsController(popController)),
            "post-upgrade: the PoP controller mapping survives the swap"
        );

        // The gateway-cold path stashes a pending label, so a soulbound mint takes an empty label
        // and never touches the store.
        uint256 gatewayToken = uint256(keccak256("dotns.fork.upgrade.gateway"));
        vm.prank(popController);
        registrar.register(gatewayToken, alice, "");
        assertTrue(registrar.isSoulbound(gatewayToken), "gateway mint is soulbound");

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRegistrar.NameSoulbound.selector, gatewayToken)
        );
        registrar.transferFrom(alice, bob, gatewayToken);

        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRegistrar.NameSoulbound.selector, gatewayToken)
        );
        registrar.quoteTransferFee(gatewayToken, bob);
    }
}
