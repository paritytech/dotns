// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DotnsCostModelRegistry} from "../../../contracts/pop/DotnsCostModelRegistry.sol";
import {IDotnsCostModelRegistry} from "../../../contracts/pop/IDotnsCostModelRegistry.sol";
import {DotnsScarcityPricing} from "../../../contracts/pop/DotnsScarcityPricing.sol";
import {IDotnsPricing} from "../../../contracts/pop/IDotnsPricing.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";

/// @title ZeroVersionModel
/// @notice Minimal cost model whose version identifier is zero, used to exercise the registry's
///         zero-version guard.
contract ZeroVersionModel is IDotnsPricing {
    function priceForBaseLength(uint256) external pure override returns (uint256 weiPrice) {
        return 1 ether;
    }

    function version() external pure override returns (uint256 modelVersion) {
        return 0;
    }
}

/// @title DotnsCostModelRegistryTests
/// @notice Unit tests for model registration, current-version tracking, and versioned pricing.
/// @notice Stands in for the protocol registry, which holds the bootstrap owner.
contract OwnerHolder {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function renounceOwnership() external {
        owner = address(0);
    }
}

contract DotnsCostModelRegistryTests is Test {
    uint256 internal constant BASE_FEE = 10 ether;
    uint256 internal constant FLOOR = 0.1 ether;

    address internal owner;
    OwnerHolder internal holder;
    DotnsCostModelRegistry internal registry;
    DotnsScarcityPricing internal modelA;
    DotnsScarcityPricing internal modelB;

    function setUp() public {
        owner = makeAddr("owner");
        holder = new OwnerHolder(owner);
        registry = new DotnsCostModelRegistry(IDotnsProtocolRegistry(address(holder)));
        modelA = new DotnsScarcityPricing(BASE_FEE, FLOOR);
        modelB = new DotnsScarcityPricing(BASE_FEE * 2, FLOOR);

        vm.prank(owner);
        registry.register(IDotnsPricing(address(modelA)));
    }

    function test_register_sets_current_version_and_model() public view {
        assertEq(registry.currentVersion(), modelA.version());
        assertEq(address(registry.current()), address(modelA));
        assertEq(registry.priceForBaseLength(9), BASE_FEE);
    }

    function test_register_only_owner() public {
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        registry.register(IDotnsPricing(address(modelB)));
    }

    function test_register_reverts_on_duplicate_version() public {
        uint256 versionA = modelA.version();
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsCostModelRegistry.AlreadyRegistered.selector, versionA)
        );
        registry.register(IDotnsPricing(address(modelA)));
    }

    function test_second_model_moves_current_but_keeps_old_priceable() public {
        vm.prank(owner);
        registry.register(IDotnsPricing(address(modelB)));

        // Current now serves model B.
        assertEq(registry.currentVersion(), modelB.version());
        assertEq(registry.priceForBaseLength(9), BASE_FEE * 2);

        // Both versions stay priceable by version.
        assertEq(registry.priceForBaseLengthAtVersion(modelA.version(), 9), BASE_FEE);
        assertEq(registry.priceForBaseLengthAtVersion(modelB.version(), 9), BASE_FEE * 2);
    }

    function test_unknown_version_reverts() public {
        uint256 unknown = uint256(keccak256("no such version"));
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsCostModelRegistry.UnknownVersion.selector, unknown)
        );
        registry.priceForBaseLengthAtVersion(unknown, 9);
    }

    function test_setCurrentVersion_reverts_to_older_version() public {
        DotnsScarcityPricing modelC = new DotnsScarcityPricing(BASE_FEE * 4, FLOOR);
        vm.startPrank(owner);
        registry.register(IDotnsPricing(address(modelB)));
        registry.register(IDotnsPricing(address(modelC)));
        // Point current back at the first version.
        registry.setCurrentVersion(modelA.version());
        vm.stopPrank();

        assertEq(registry.currentVersion(), modelA.version());
        assertEq(address(registry.current()), address(modelA));
        assertEq(registry.priceForBaseLength(9), BASE_FEE);

        // The other versions stay queryable at their own amounts.
        assertEq(registry.priceForBaseLengthAtVersion(modelB.version(), 9), BASE_FEE * 2);
        assertEq(registry.priceForBaseLengthAtVersion(modelC.version(), 9), BASE_FEE * 4);
    }

    function test_setCurrentVersion_reverts_for_unknown_version() public {
        uint256 unknown = uint256(keccak256("never registered"));
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IDotnsCostModelRegistry.UnknownVersion.selector, unknown)
        );
        registry.setCurrentVersion(unknown);
    }

    function test_setCurrentVersion_only_owner() public {
        uint256 versionA = modelA.version();
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        registry.setCurrentVersion(versionA);
    }

    function test_register_reverts_for_zero_version() public {
        ZeroVersionModel zeroModel = new ZeroVersionModel();
        vm.prank(owner);
        vm.expectRevert(IDotnsCostModelRegistry.ZeroVersion.selector);
        registry.register(IDotnsPricing(address(zeroModel)));
    }

    function test_register_emits_cost_model_registered() public {
        uint256 versionB = modelB.version();
        vm.expectEmit(true, true, false, false, address(registry));
        emit IDotnsCostModelRegistry.CostModelRegistered(versionB, address(modelB));
        vm.prank(owner);
        registry.register(IDotnsPricing(address(modelB)));
    }

    function test_setCurrentVersion_emits_current_model_set() public {
        uint256 versionB = modelB.version();
        vm.prank(owner);
        registry.register(IDotnsPricing(address(modelB)));

        uint256 versionA = modelA.version();
        vm.expectEmit(true, false, false, false, address(registry));
        emit IDotnsCostModelRegistry.CurrentModelSet(versionA);
        vm.prank(owner);
        registry.setCurrentVersion(versionA);
    }
}
