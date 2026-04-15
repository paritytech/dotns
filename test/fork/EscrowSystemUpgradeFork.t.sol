// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {DotnsProtocolRegistry} from "../../contracts/registry/DotnsProtocolRegistry.sol";
import {DotnsRegistry, IDotnsRegistry} from "../../contracts/registry/DotnsRegistry.sol";
import {DotnsNameEscrow, IDotnsNameEscrow} from "../../contracts/escrow/DotnsNameEscrow.sol";
import {DotnsRegistrar, IDotnsRegistrar} from "../../contracts/registrars/DotnsRegistrar.sol";
import {
    DotnsRegistrarController,
    IDotnsRegistrarController
} from "../../contracts/registrars/DotnsRegistrarController.sol";
import {IDotnsController} from "../../contracts/registrars/IDotnsController.sol";
import {IPopRules} from "../../contracts/pop/IPopRules.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";

import {UpgradeEscrowSystem} from "../../scripts/deploy/UpgradeEscrowSystem.s.sol";

/// @title Full escrow-system fork test against live Paseo AssetHub
/// @notice Applies the upgrade via `UpgradeEscrowSystem.upgradeAll` (single source of truth)
///         and exercises the complete end-to-end flow: register, subname, transfer, release,
///         withdraw, finalise. Production and test share one upgrade code path.
/// @dev Pre-upgrade live proxies host the *Old.sol implementations
///      ({DotnsProtocolRegistryOld}, {DotnsRegistryOld}, {DotnsRegistrarOld},
///      {DotnsRegistrarControllerOld}); the OZ upgrade flow validates layout
///      against those references and swaps in the new ones. After
///      `upgradeAll`, every cast in this test is to the new (non-Old) type and
///      protocol-registry keys are read from {DotnsConstants}, since the new
///      {DotnsProtocolRegistry} no longer exposes the keys as public getters.
contract EscrowSystemUpgradeForkTest is Test {
    UpgradeEscrowSystem public upgradeScript;

    DotnsProtocolRegistry public registry;
    DotnsNameEscrow public escrow;
    DotnsRegistrar public registrar;
    DotnsRegistrarController public controller;
    IPopRules public popRules;

    address public registryOwner;
    address public registrarOwner;
    address public controllerOwner;

    address public alice;
    address public bob;

    function setUp() public {
        vm.createSelectFork("paseo");

        upgradeScript = new UpgradeEscrowSystem();

        registry = DotnsProtocolRegistry(upgradeScript.PROTOCOL_REGISTRY_PROXY());
        registrar = DotnsRegistrar(upgradeScript.REGISTRAR_PROXY());
        controller = DotnsRegistrarController(upgradeScript.CONTROLLER_PROXY());

        registryOwner = OwnableUpgradeable(address(registry)).owner();
        registrarOwner = OwnableUpgradeable(address(registrar)).owner();
        controllerOwner = OwnableUpgradeable(address(controller)).owner();

        address escrowProxy =
            upgradeScript.upgradeAll(registryOwner, registrarOwner, controllerOwner);
        escrow = DotnsNameEscrow(payable(escrowProxy));

        upgradeScript.verifyUpgrade(escrowProxy);

        popRules = IPopRules(registry.get(DotnsConstants.POP_RULES));

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function test_versions_bumped() public view {
        assertEq(registry.version(), upgradeScript.PROTOCOL_REGISTRY_VERSION());
        IDotnsRegistry forwardRegistry = IDotnsRegistry(registry.get(DotnsConstants.REGISTRY));
        assertEq(
            DotnsRegistry(address(forwardRegistry)).version(), upgradeScript.REGISTRY_VERSION()
        );
        assertEq(registrar.version(), upgradeScript.REGISTRAR_VERSION());
        assertEq(controller.version(), upgradeScript.CONTROLLER_VERSION());
        assertEq(escrow.version(), upgradeScript.ESCROW_VERSION());
    }

    function test_name_escrow_wired_in_registry() public view {
        assertEq(registry.get(DotnsConstants.NAME_ESCROW), address(escrow));
    }

    function test_existing_registry_keys_preserved() public view {
        assertTrue(registry.get(DotnsConstants.REGISTRAR) != address(0));
        assertTrue(registry.get(DotnsConstants.CONTROLLER) != address(0));
        assertTrue(registry.get(DotnsConstants.REGISTRY) != address(0));
        assertTrue(registry.get(DotnsConstants.POP_RULES) != address(0));
    }

    function test_registrar_erc721_metadata_preserved() public view {
        assertEq(registrar.name(), "Dotns");
        assertEq(registrar.symbol(), "Dotns");
    }

    /// @notice Confirms the upgraded registrar still recognises the live commit-reveal
    ///         controller via the new {IDotnsController} baseline mapping.
    /// @dev The controller mapping was retyped from {IDotnsRegistrarControllerOld} to
    ///      {IDotnsController} in the upgrade — the storage slot is preserved (OZ
    ///      `@custom:oz-retyped-from`), and post-upgrade reads MUST use the new type.
    function test_registrar_controller_wiring_preserved() public view {
        assertTrue(
            registrar.controllers(IDotnsController(address(controller))),
            "controller still authorised on registrar after upgrade"
        );
    }

    /// @notice Exercises the full lifecycle on top of the freshly upgraded system.
    /// @dev Single test by design — it's one continuous user journey; splitting it would
    ///      require duplicating expensive setup (commit/reveal + onchain writes).
    function test_full_user_flow_after_upgrade() public {
        string memory label = "longerforkfx14";
        bytes32 labelhash = keccak256(bytes(label));
        bytes32 node = keccak256(abi.encodePacked(DotnsConstants.DOT_NODE, labelhash));
        uint256 tokenId = uint256(node);
        uint256 escrowBalanceBefore = address(escrow).balance;
        uint256 reservesBefore = escrow.reserves(address(0));

        uint256 price = _commitAndRegister(label, alice);

        assertEq(registrar.ownerOf(tokenId), alice, "alice owns the token");
        assertEq(address(escrow).balance, escrowBalanceBefore + price, "escrow received deposit");
        assertEq(escrow.reserves(address(0)), reservesBefore + price, "reserves bumped");

        IDotnsNameEscrow.ReleasePosition memory pos = escrow.getReleasePosition(tokenId);
        assertEq(pos.amount, price, "position amount == price");
        assertFalse(pos.released, "not released yet");
        IDotnsRegistry forwardRegistry = IDotnsRegistry(registry.get(DotnsConstants.REGISTRY));
        IDotnsRegistry.SubnodeRecord memory sub = IDotnsRegistry.SubnodeRecord({
            parentNode: node, subLabel: "pay", parentLabel: label, owner: alice
        });
        vm.prank(alice);
        bytes32 subnode = forwardRegistry.setSubnodeOwner(sub);
        assertEq(forwardRegistry.owner(subnode), alice, "alice owns subname");
        vm.prank(alice);
        registrar.transferFrom(alice, bob, tokenId);
        assertEq(registrar.ownerOf(tokenId), bob, "bob now owns the token");

        vm.prank(bob);
        registrar.approve(address(escrow), tokenId);

        vm.prank(bob);
        escrow.release(tokenId);

        assertEq(registrar.ownerOf(tokenId), address(escrow), "escrow owns token after release");
        pos = escrow.getReleasePosition(tokenId);
        assertEq(pos.recipient, bob, "bob snapshotted as refund recipient");
        assertTrue(pos.released, "released flag set");
        assertEq(escrow.releasedTokenCount(), 1, "released set grew");
        vm.warp(block.timestamp + escrow.cooldown() + 1);
        uint256 bobBalanceBefore = bob.balance;

        vm.prank(bob);
        escrow.withdraw(tokenId);

        assertEq(bob.balance - bobBalanceBefore, price, "bob received refund");
        pos = escrow.getReleasePosition(tokenId);
        assertEq(pos.amount, 0, "position amount zeroed after withdraw");
        assertTrue(pos.claimed, "claimed flag set");
        assertEq(
            escrow.reserves(address(0)), reservesBefore, "reserves returned to pre-register level"
        );

        // Escrow retains custody of the NFT until the next registrant reclaims it.
        assertEq(
            registrar.ownerOf(tokenId),
            address(escrow),
            "escrow retains custody after withdraw"
        );
        assertTrue(
            registrar.available(tokenId),
            "name available for reclaim via re-registration"
        );

        // Subname ownership persists through the custody hand-off — the new parent owner
        // inherits parent authority and can reassign via setSubnodeOwner if desired.
        assertEq(
            forwardRegistry.owner(subnode),
            alice,
            "subname record persists; new parent owner can reassign"
        );

        address charlie = makeAddr("charlie");
        vm.deal(charlie, 100 ether);

        uint256 reservesBeforeReregister = escrow.reserves(address(0));
        uint256 newPrice = _commitAndRegister(label, charlie);

        assertEq(registrar.ownerOf(tokenId), charlie, "charlie owns the re-registered name");
        assertEq(
            escrow.reserves(address(0)),
            reservesBeforeReregister + newPrice,
            "fresh deposit recorded for re-registration"
        );
        assertEq(escrow.releasedTokenCount(), 0, "released set drained after reclaim");

        IDotnsNameEscrow.ReleasePosition memory freshPos = escrow.getReleasePosition(tokenId);
        assertEq(freshPos.amount, newPrice, "fresh position amount");
        assertFalse(freshPos.released, "fresh position not released");
        assertFalse(freshPos.claimed, "fresh position not claimed");
    }

    function test_migrateNativeFundsToEscrow_gated_to_controller_owner() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker)
        );
        controller.migrateNativeFundsToEscrow(1 wei);
    }

    function test_escrow_deposit_gated_to_controller() public {
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IDotnsNameEscrow.NotController.selector, attacker));
        escrow.deposit{value: 1 wei}(
            IDotnsNameEscrow.DepositParams({tokenId: 1, asset: address(0), amount: 1 wei})
        );
    }

    /// @notice Commits, waits the minimum age, registers, returns the price paid.
    function _commitAndRegister(
        string memory label,
        address owner
    )
        internal
        returns (uint256 price)
    {
        bytes32 secret = keccak256(abi.encodePacked(label, owner, block.timestamp));
        IDotnsRegistrarController.Registration memory reg = IDotnsRegistrarController.Registration({
            label: label, owner: owner, secret: secret, reserved: false
        });

        bytes32 commitment = controller.makeCommitment(reg);
        vm.prank(owner);
        controller.commit(commitment);

        vm.warp(block.timestamp + controller.minCommitmentAge() + 1);

        price = popRules.priceWithCheck(label, owner).price;
        vm.prank(owner);
        controller.register{value: price}(reg);
    }
}
