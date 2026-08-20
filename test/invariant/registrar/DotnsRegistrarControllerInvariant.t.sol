// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {ILabelStore} from "../../../contracts/store/ILabelStore.sol";
import {RegistrarControllerHandler} from "./RegistrarControllerHandler.t.sol";

/// @title DotnsRegistrarControllerInvariantTest
/// @notice Invariants asserted over arbitrary sequences of registrar-controller
///         actions including commit-reveal registration and ownership transfer.
contract DotnsRegistrarControllerInvariantTest is BaseDotns {
    /// @notice Bounded random-action handler driving the controller under test.
    RegistrarControllerHandler public handler;

    /// @notice Wires the handler, seeds it with mixed-status actors, funds it
    ///         for paid registrations, and excludes protocol contracts from
    ///         direct fuzzer dispatch.
    function setUp() public override {
        super.setUp();

        handler = new RegistrarControllerHandler(
            dotnsRegistrarController,
            dotnsRegistry,
            dotnsRegistrar,
            dotnsReverseResolver,
            popRules,
            storeFactory,
            protocolRegistry.tldNode()
        );

        vm.deal(address(handler), 1000 ether);

        handler.addActor(ed, IPopRules.PopStatus.PopFull);
        handler.addActor(leonardo, IPopRules.PopStatus.PopLite);
        handler.addActor(tiago, IPopRules.PopStatus.NoStatus);

        // Additional actors for richer multi-user transfer chains.
        address alice = _createUser("alice");
        address bob = _createUser("bob");
        handler.addActor(alice, IPopRules.PopStatus.PopFull);
        handler.addActor(bob, IPopRules.PopStatus.PopLite);

        targetContract(address(handler));

        excludeContract(address(dotnsRegistrarController));
        excludeContract(address(dotnsRegistry));
        excludeContract(address(dotnsRegistrar));
        excludeContract(address(popRules));
        excludeContract(address(storeFactory));
    }

    /// @notice Every successfully registered name reports `available == false`
    ///         on the controller.
    function invariant_registered_names_unavailable() public view {
        string[] memory registeredLabels = handler.getRegisteredLabels();

        for (uint256 i; i < registeredLabels.length; ++i) {
            assertFalse(
                dotnsRegistrarController.available(registeredLabels[i]),
                "Registered name must be unavailable"
            );
        }
    }

    /// @notice Commitments consumed by a successful registration are deleted
    ///         from the controller's commitment book (no replay).
    function invariant_consumed_commitments_deleted() public view {
        bytes32[] memory consumedCommitments = handler.getConsumedCommitments();

        for (uint256 i; i < consumedCommitments.length; ++i) {
            assertEq(
                dotnsRegistrarController.commitments(consumedCommitments[i]),
                0,
                "Consumed commitment must be deleted"
            );
        }
    }

    /// @notice Every registered name's store entry is locked against
    ///         mutation by anyone other than the controller.
    function invariant_store_entries_locked() public view {
        string[] memory registeredLabels = handler.getRegisteredLabels();
        address[] memory registeredOwners = handler.getRegisteredOwners();

        for (uint256 i; i < registeredLabels.length; ++i) {
            address registrationOwner = registeredOwners[i];
            ILabelStore store = ILabelStore(storeFactory.getLabelStore(registrationOwner));

            if (address(store) != address(0)) {
                bytes32 node = _namehash(dotNode, keccak256(bytes(registeredLabels[i])));

                assertTrue(store.isLocked(node), "Store entry must be locked");
            }
        }
    }

    /// @notice The controller never accumulates a residual balance; refunds
    ///         and price transfers always net to zero on its side.
    function invariant_no_stuck_funds() public view {
        assertEq(address(dotnsRegistrarController).balance, 0, "Controller must not hold funds");
    }

    function invariant_value_conservation() public view {
        // Escrow balance equals reserves + insurance + pending withdrawals.
        uint256 reservedAmount = dotnsNameEscrow.reserves(address(0));
        uint256 insurance = dotnsNameEscrow.insuranceFund();

        uint256 pendingTotal;
        for (uint256 i; i < 5; ++i) {
            try handler.actors(i) returns (address actor) {
                pendingTotal += dotnsNameEscrow.pendingWithdrawal(actor);
            } catch {
                break;
            }
        }

        uint256 escrowBalance = address(dotnsNameEscrow).balance;
        assertEq(
            escrowBalance,
            reservedAmount + insurance + pendingTotal,
            "Escrow balance must equal reserves + insurance + pending withdrawals"
        );
    }

    /// @notice The ghost registration counter matches the count of recorded
    ///         labels and the count of live ERC721 tokens at their nodes.
    function invariant_registration_count_consistent() public view {
        uint256 registrationCount = handler.getRegistrationCount();
        string[] memory registeredLabels = handler.getRegisteredLabels();

        assertEq(
            registrationCount,
            registeredLabels.length,
            "Registration count must match labels array length"
        );

        uint256 validTokenCount;

        for (uint256 i; i < registeredLabels.length; ++i) {
            bytes32 labelhash = keccak256(bytes(registeredLabels[i]));
            bytes32 node = _namehash(dotNode, labelhash);
            uint256 tokenId = uint256(node);

            try dotnsRegistrar.ownerOf(tokenId) returns (address tokenOwner) {
                if (tokenOwner != address(0)) {
                    ++validTokenCount;
                }
            } catch {}
        }

        assertEq(
            validTokenCount, registrationCount, "Valid token count must match registration count"
        );
    }

    /// @notice Every reserved registration produces a reverse-resolution entry
    ///         of the form `<label>.dot` for the reserved owner.
    function invariant_reserved_names_have_reverse_resolution() public view {
        string[] memory reservedLabels = handler.getReservedLabels();
        address[] memory reservedOwners = handler.getReservedOwners();

        for (uint256 i; i < reservedLabels.length; ++i) {
            string memory expectedName = string.concat(reservedLabels[i], ".dot");
            string memory actualName = dotnsReverseResolver.nameOf(reservedOwners[i]);

            assertEq(actualName, expectedName, "Reverse resolution must be set for reserved name");
        }
    }

    /// @notice Every transfer recipient ends up with a deployed store
    ///         containing the transferred label, locked against external
    ///         mutation.
    function invariant_transfer_recipients_have_store_entries() public view {
        string[] memory transferredLabels = handler.getTransferredLabels();
        address[] memory transferredRecipients = handler.getTransferredRecipients();

        for (uint256 i; i < transferredLabels.length; ++i) {
            address recipient = transferredRecipients[i];
            ILabelStore store = ILabelStore(storeFactory.getLabelStore(recipient));

            assertTrue(address(store) != address(0), "Transfer recipient must have a store");

            bytes32 node = _namehash(dotNode, keccak256(bytes(transferredLabels[i])));

            assertEq(
                store.getLabel(node),
                string.concat(transferredLabels[i], ".dot"),
                "Transfer-created store entry must contain correct label"
            );

            assertTrue(store.isLocked(node), "Transfer-created store entry must be locked");
        }
    }

    /// @notice The current owner of every registered name has a store entry
    ///         carrying the canonical `<label>.dot` value, irrespective of
    ///         how many transfer hops the name has gone through.
    function invariant_current_owners_have_label_in_store() public view {
        string[] memory registeredLabels = handler.getRegisteredLabels();
        address[] memory registeredOwners = handler.getRegisteredOwners();

        for (uint256 i; i < registeredLabels.length; ++i) {
            address currentOwner = registeredOwners[i];
            ILabelStore store = ILabelStore(storeFactory.getLabelStore(currentOwner));

            assertTrue(address(store) != address(0), "Current owner must have a store");

            bytes32 node = _namehash(dotNode, keccak256(bytes(registeredLabels[i])));

            assertEq(
                store.getLabel(node),
                string.concat(registeredLabels[i], ".dot"),
                "Current owner store must contain correct label after any number of transfers"
            );
        }
    }

    /// @notice The forward registry's `owner(node)` always matches the ERC721
    ///         `ownerOf(tokenId)` for every registered name.
    function invariant_ownership_consistency() public view {
        string[] memory registeredLabels = handler.getRegisteredLabels();

        for (uint256 i; i < registeredLabels.length; ++i) {
            bytes32 labelhash = keccak256(bytes(registeredLabels[i]));
            bytes32 node = _namehash(dotNode, labelhash);
            uint256 tokenId = uint256(node);

            try dotnsRegistrar.ownerOf(tokenId) returns (address tokenOwner) {
                address registryOwner = dotnsRegistry.owner(node);
                assertEq(
                    registryOwner, tokenOwner, "Registry owner must match current ERC721 owner"
                );
            } catch {}
        }
    }
}
