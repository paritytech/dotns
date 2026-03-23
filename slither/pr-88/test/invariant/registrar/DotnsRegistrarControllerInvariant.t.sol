// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {Store} from "../../../contracts/store/Store.sol";
import {RegistrarControllerHandler} from "./RegistrarControllerHandler.t.sol";

contract DotnsRegistrarControllerInvariantTest is BaseDotns {
    RegistrarControllerHandler public handler;

    function setUp() public override {
        super.setUp();

        handler = new RegistrarControllerHandler(
            dotnsRegistrarController,
            dotnsRegistry,
            dotnsRegistrar,
            dotnsReverseResolver,
            popRules,
            storeFactory
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

    function invariant_registered_names_unavailable() public view {
        string[] memory registeredLabels = handler.getRegisteredLabels();

        for (uint256 i; i < registeredLabels.length; ++i) {
            assertFalse(
                dotnsRegistrarController.available(registeredLabels[i]),
                "Registered name must be unavailable"
            );
        }
    }

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

    function invariant_store_entries_locked() public view {
        string[] memory registeredLabels = handler.getRegisteredLabels();
        address[] memory registeredOwners = handler.getRegisteredOwners();

        for (uint256 i; i < registeredLabels.length; ++i) {
            address registrationOwner = registeredOwners[i];
            Store store = Store(address(storeFactory.getDeployedStore(registrationOwner)));

            if (address(store) != address(0)) {
                bytes32 labelhash = keccak256(bytes(registeredLabels[i]));
                bytes32 storeKey = _storeKey(labelhash);

                assertTrue(
                    store.isLocked(registrationOwner, storeKey), "Store entry must be locked"
                );
            }
        }
    }

    function invariant_no_stuck_funds() public view {
        assertEq(address(dotnsRegistrarController).balance, 0, "Controller must not hold funds");
    }

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

    function invariant_reserved_names_have_reverse_resolution() public view {
        string[] memory reservedLabels = handler.getReservedLabels();
        address[] memory reservedOwners = handler.getReservedOwners();

        for (uint256 i; i < reservedLabels.length; ++i) {
            string memory expectedName = string.concat(reservedLabels[i], ".dot");
            string memory actualName = dotnsReverseResolver.nameOf(reservedOwners[i]);

            assertEq(actualName, expectedName, "Reverse resolution must be set for reserved name");
        }
    }

    function invariant_transfer_recipients_have_store_entries() public view {
        string[] memory transferredLabels = handler.getTransferredLabels();
        address[] memory transferredRecipients = handler.getTransferredRecipients();

        for (uint256 i; i < transferredLabels.length; ++i) {
            address recipient = transferredRecipients[i];
            Store store = Store(address(storeFactory.getDeployedStore(recipient)));

            assertTrue(address(store) != address(0), "Transfer recipient must have a store");

            bytes32 labelhash = keccak256(bytes(transferredLabels[i]));
            bytes32 storeKey = _storeKey(labelhash);

            assertEq(
                store.getValueFor(recipient, storeKey),
                string.concat(transferredLabels[i], ".dot"),
                "Transfer-created store entry must contain correct label"
            );

            assertTrue(
                store.isLocked(recipient, storeKey), "Transfer-created store entry must be locked"
            );
        }
    }

    function invariant_current_owners_have_label_in_store() public view {
        string[] memory registeredLabels = handler.getRegisteredLabels();
        address[] memory registeredOwners = handler.getRegisteredOwners();

        for (uint256 i; i < registeredLabels.length; ++i) {
            address currentOwner = registeredOwners[i];
            Store store = Store(address(storeFactory.getDeployedStore(currentOwner)));

            assertTrue(address(store) != address(0), "Current owner must have a store");

            bytes32 labelhash = keccak256(bytes(registeredLabels[i]));
            bytes32 storeKey = _storeKey(labelhash);

            assertEq(
                store.getValueFor(currentOwner, storeKey),
                string.concat(registeredLabels[i], ".dot"),
                "Current owner store must contain correct label after any number of transfers"
            );
        }
    }

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
