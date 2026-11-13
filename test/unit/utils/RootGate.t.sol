// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";
import {IDotnsNameWhitelist} from "../../../contracts/whitelist/IDotnsNameWhitelist.sol";
import {IDotnsNameEscrowGovernance} from "../../../contracts/escrow/IDotnsNameEscrowGovernance.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {IDotnsRegistrar} from "../../../contracts/registrars/IDotnsRegistrar.sol";
import {IDotnsRegistry} from "../../../contracts/registry/IDotnsRegistry.sol";
import {IDotnsPopController} from "../../../contracts/registrars/IDotnsPopController.sol";
import {IDotnsPopGovernance} from "../../../contracts/registrars/IDotnsPopGovernance.sol";
import {
    IDotnsRegistrarController
} from "../../../contracts/registrars/IDotnsRegistrarController.sol";

/// @notice Stand-in for revive's System precompile that answers `callerIsRoot` per contract, as
///         the runtime does: true only in the contract a Root dispatch targets, including behind
///         its proxy, and false in any contract that contract calls.
contract CallerAwareSystem {
    address public rootTarget;

    function setRootTarget(address target) external {
        rootTarget = target;
    }

    function callerIsRoot() external view returns (bool) {
        return rootTarget != address(0) && msg.sender == rootTarget;
    }

    /// @dev True for the whole Root transaction, so a gate reading it would let a reached
    ///      contract through and fail these tests.
    function originIsRoot() external view returns (bool) {
        return rootTarget != address(0);
    }
}

/// @notice A contract a Root dispatch reaches, forwarding a call into dotNS.
contract RootReachedContract {
    function forward(address target, bytes calldata data) external {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/// @title RootGateTests
/// @notice Every Root gate passes only in the contract Root dispatched to. A contract reached
///         during the same Root transaction holds no dotNS governance.
contract RootGateTests is BaseDotns {
    CallerAwareSystem private constant SYSTEM = CallerAwareSystem(DotnsConstants.REVIVE_SYSTEM);

    RootReachedContract private reached;

    function setUp() public override {
        super.setUp();
        vm.clearMockedCalls();
        vm.etch(DotnsConstants.REVIVE_SYSTEM, address(new CallerAwareSystem()).code);
        reached = new RootReachedContract();
    }

    function test_whitelist_gate_passes_for_a_direct_root_dispatch() public {
        SYSTEM.setRootTarget(address(dotnsNameWhitelist));

        dotnsNameWhitelist.grantName("alpha", ed);

        assertEq(dotnsNameWhitelist.granteeOf("alpha"), ed);
    }

    function test_popRules_gate_passes_for_a_direct_root_dispatch() public {
        SYSTEM.setRootTarget(address(popRules));

        popRules.setShortNamesEnabled(true);

        assertTrue(popRules.shortNamesEnabled());
    }

    function test_revert_whitelist_gate_refuses_a_contract_root_reached() public {
        SYSTEM.setRootTarget(address(reached));

        vm.expectRevert(IDotnsNameWhitelist.NotGovernance.selector);
        reached.forward(
            address(dotnsNameWhitelist),
            abi.encodeCall(IDotnsNameWhitelist.grantName, ("alpha", ed))
        );
    }

    function test_revert_popRules_gate_refuses_a_contract_root_reached() public {
        SYSTEM.setRootTarget(address(reached));

        vm.expectRevert(IPopRules.NotRoot.selector);
        reached.forward(address(popRules), abi.encodeCall(IPopRules.setShortNamesEnabled, (true)));
    }

    function test_revert_registrar_gate_refuses_a_contract_root_reached() public {
        SYSTEM.setRootTarget(address(reached));

        vm.expectRevert(IDotnsRegistrar.NotRoot.selector);
        reached.forward(address(dotnsRegistrar), abi.encodeCall(IDotnsRegistrar.revoke, (1)));
    }

    function test_revert_registry_gate_refuses_a_contract_root_reached() public {
        SYSTEM.setRootTarget(address(reached));

        vm.expectRevert(IDotnsRegistry.NotRoot.selector);
        reached.forward(
            address(dotnsRegistry),
            abi.encodeCall(IDotnsRegistry.revokeSubname, (bytes32(0), bytes32(0)))
        );
    }

    function test_revert_popController_gate_refuses_a_contract_root_reached() public {
        SYSTEM.setRootTarget(address(reached));

        vm.expectRevert(IDotnsPopController.NotRoot.selector);
        reached.forward(
            address(dotnsPopController),
            abi.encodeCall(IDotnsPopGovernance.evictReservations, ("alpha"))
        );
    }

    function test_revert_escrow_gate_refuses_a_contract_root_reached() public {
        SYSTEM.setRootTarget(address(reached));

        vm.expectRevert(IDotnsNameEscrowGovernance.NotRoot.selector);
        reached.forward(
            address(dotnsNameEscrow),
            abi.encodeCall(IDotnsNameEscrowGovernance.withdrawProtocolFees, (ed, 1))
        );
    }

    /// @notice A reached contract gets the grantee path, so the free Root mint is out of reach.
    function test_registerReserved_treats_a_contract_root_reached_as_a_grantee() public {
        SYSTEM.setRootTarget(address(reached));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: "alpha",
                owner: ed,
                secret: bytes32(0),
                reserved: true,
                maxPrice: 0,
                pricingVersion: 0
            });

        vm.expectRevert(
            abi.encodeWithSelector(IDotnsRegistrarController.NameNotGranted.selector, "alpha", ed)
        );
        reached.forward(
            address(dotnsRegistrarController),
            abi.encodeCall(IDotnsRegistrarController.registerReserved, (registration))
        );
    }
}
