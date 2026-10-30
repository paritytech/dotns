// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BasePopFork} from "./BasePopFork.t.sol";
import {UpgradeRegistrarController} from "../../scripts/deploy/UpgradeRegistrarController.s.sol";
import {IDotnsRegistrarController} from "../../contracts/registrars/IDotnsRegistrarController.sol";
import {DotnsRegistrarController} from "../../contracts/registrars/DotnsRegistrarController.sol";
import {IDotnsNameEscrow} from "../../contracts/escrow/IDotnsNameEscrow.sol";
import {IPopRules} from "../../contracts/pop/IPopRules.sol";

/// @title UpgradeRegistrarControllerHarness
/// @notice Exposes the upgrade script's internal path so the test drives the code the production
///         run executes, including the fail-closed storage-layout diff.
contract UpgradeRegistrarControllerHarness is UpgradeRegistrarController {
    /// @notice Upgrades `proxy` under `owner` through the script's own internal.
    function upgrade(address owner, address proxy) external {
        _upgradeRegistrarController(owner, proxy);
    }
}

/// @title UpgradeRegistrarControllerForkTest
/// @notice Pairs one-to-one with `scripts/deploy/UpgradeRegistrarController.s.sol`. Proves the
///         live configuration survives the swap and that a governance mint becomes releasable.
/// @dev Requires the local ETH-RPC adapter on `paseo_local`, or `PASEO_FORK_RPC`; see
///      `DEPLOYMENTS.md`. Run the suite with `bun run test:fork`.
/// @custom:security-contact admin@parity.io
contract UpgradeRegistrarControllerForkTest is BasePopFork {
    /// @notice Label minted before the swap, chosen to be unregistered on Paseo.
    string internal constant LABEL_BEFORE = "zqxforkreservedone";

    /// @notice Label minted after the swap, chosen to be unregistered on Paseo.
    string internal constant LABEL_AFTER = "zqxforkreservedtwo";

    /// @notice The deployed proxy under upgrade.
    address internal proxy;

    /// @notice Proxy owner, the broadcaster the script requires.
    address internal proxyOwner;

    /// @notice Account the governance mints name as owner.
    address internal beneficiary;

    /// @notice Drives the script's upgrade path against the live proxy.
    UpgradeRegistrarControllerHarness internal upgrader;

    function setUp() public override {
        super.setUp();
        proxy = _live("DotnsRegistrarController");
        proxyOwner = _ownerOf(proxy);
        beneficiary = makeAddr("beneficiary");
        upgrader = new UpgradeRegistrarControllerHarness();
    }

    /// @notice The swap lands and the commitment window and owner survive it.
    function test_upgrade_preserves_live_configuration() public {
        DotnsRegistrarController controller = DotnsRegistrarController(proxy);
        address implementationBefore = _implementationOf(proxy);
        uint256 minAgeBefore = controller.minCommitmentAge();
        uint256 maxAgeBefore = controller.maxCommitmentAge();

        upgrader.upgrade(proxyOwner, proxy);

        assertTrue(_implementationOf(proxy) != implementationBefore, "the implementation changed");
        assertEq(_ownerOf(proxy), proxyOwner, "owner preserved");
        assertEq(controller.minCommitmentAge(), minAgeBefore, "min commitment age preserved");
        assertEq(controller.maxCommitmentAge(), maxAgeBefore, "max commitment age preserved");
    }

    /// @notice A governance mint opens no release position before the swap and opens one for
    ///         the owner after it, which is what makes the name releasable.
    function test_governance_mint_becomes_releasable() public {
        IDotnsNameEscrow escrow = IDotnsNameEscrow(payable(_live("DotnsNameEscrow")));

        uint256 tokenBefore = _governanceMint(LABEL_BEFORE);
        assertEq(
            escrow.getReleasePosition(tokenBefore).recipient,
            address(0),
            "the deployed controller opens no position"
        );

        upgrader.upgrade(proxyOwner, proxy);

        uint256 tokenAfter = _governanceMint(LABEL_AFTER);
        IDotnsNameEscrow.ReleasePosition memory position = escrow.getReleasePosition(tokenAfter);
        assertEq(position.recipient, beneficiary, "the position names the owner");
        assertEq(position.amount, 0, "a governance mint carries no deposit");
    }

    /// @notice Mints `label` to `beneficiary` through `registerReserved` under a Root origin.
    /// @param label Unregistered label.
    /// @return tokenId Token id of the minted name.
    function _governanceMint(string memory label) internal returns (uint256 tokenId) {
        bytes32 node = _nodeOf(label);
        _requireUnregistered(node);
        IDotnsRegistrarController controller = IDotnsRegistrarController(proxy);
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label,
                owner: beneficiary,
                secret: keccak256(bytes(label)),
                reserved: true,
                maxPrice: 0,
                pricingVersion: IPopRules(_live("PopRules")).pricingVersion()
            });
        controller.commit(controller.makeCommitment(registration));
        vm.warp(block.timestamp + DotnsRegistrarController(proxy).minCommitmentAge());

        _mockRootOrigin();
        controller.registerReserved(registration);
        tokenId = uint256(node);
    }
}
