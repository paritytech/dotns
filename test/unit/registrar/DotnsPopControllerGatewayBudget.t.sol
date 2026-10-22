// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsPopController} from "../../../contracts/registrars/IDotnsPopController.sol";
import {IDotnsRegistry} from "../../../contracts/registry/IDotnsRegistry.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice The gateway calls the controller under a fixed weight limit, so no call may grow
///         excessively with what a reservation queue holds. These tests pin all-or-nothing queue
///         clearing, the single-call slot move when a queue is emptied and refilled, and container
///         preparation.
contract DotnsPopControllerGatewayBudgetTests is BaseDotns {
    string internal constant BASE = "longnamebob";

    /// @dev Queues `count` waiters on `BASE`, each with its own device name in container `11`,
    ///      then lets every entry expire.
    function _queueExpired(uint256 count) internal returns (address[] memory waiters) {
        waiters = new address[](count);
        for (uint256 i; i < count; ++i) {
            waiters[i] = makeAddr(string.concat("waiter", vm.toString(i)));
            string memory stem = string.concat(
                "waiter",
                string(abi.encodePacked(bytes1(uint8(0x61 + i / 26)), bytes1(uint8(0x61 + i % 26))))
            );
            _reservePop(
                waiters[i], string.concat(stem, ".11"), _validChatKey(bytes1(uint8(i + 1))), BASE
            );
        }
        vm.warp(block.timestamp + dotnsPopController.reservationDuration() + 1);
    }

    function _newcomerReserves(address newcomer) internal {
        _reservePop(newcomer, "newcomer.12", _validChatKey(0x77), BASE);
    }

    /// @dev A run longer than the limit clears over several gateway calls, each keeping its
    ///      progress. While the front is still expired, PopRules is left as it is and nobody
    ///      claims; once clearing reaches the newcomer, they claim.
    function test_gateway_reservation_keeps_its_progress_beyond_its_limit() public {
        uint256 bound = dotnsPopController.MAX_QUEUE_STEPS_PER_CALL();
        // More than twice the limit, so a claim after the first reservation still stops short.
        address[] memory waiters = _queueExpired(2 * bound + 1);
        address newcomer = makeAddr("newcomer");

        vm.recordLogs();
        _newcomerReserves(newcomer);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 labelhash = keccak256(bytes(BASE));
        (uint64 head, uint64 tail) = dotnsPopController.reservationMeta(labelhash);
        assertEq(head, bound, "the limit was cleared and kept");
        assertEq(tail, 2 * bound + 2, "newcomer queued at the back");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].emitter != address(popRules), "no PopRules call");
        }
        (address popHolder,) = popRules.getBaseNameReservation(BASE);
        assertEq(popHolder, waiters[0], "PopRules left as it was");
        assertEq(
            dotnsPopController.userReservation(waiters[0]).labelhash,
            bytes32(0),
            "the first waiter was cleared"
        );

        // Nobody claims while the front is still expired after a claim's own clearing, and the
        // holder PopRules still names cannot buy the name on the public flow.
        address[3] memory callers = [waiters[0], waiters[bound], newcomer];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectPartialRevert(IDotnsPopController.NotHolder.selector);
            _rootIssuePersonhoodName(
                IDotnsPopController.PersonhoodNameIssuance({
                    label: BASE, user: callers[i], link: _linkFresh(_validChatKey(0x55))
                })
            );
        }
        vm.expectRevert(
            abi.encodeWithSelector(
                IPopRules.PopError.selector, "Reserved for a device-name holder's personhood claim"
            )
        );
        popRules.priceWithCheck(BASE, waiters[0]);

        // The next gateway reservation carries on, clearing the limit again.
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: makeAddr("third"), label: BASE})
        );
        (head,) = dotnsPopController.reservationMeta(labelhash);
        assertEq(head, 2 * bound, "progress kept again");

        // The newcomer's claim clears the last expired entry, reaches them and succeeds.
        _rootIssuePersonhoodName(
            IDotnsPopController.PersonhoodNameIssuance({
                label: BASE, user: newcomer, link: _linkFresh(_validChatKey(0x55))
            })
        );
        assertEq(IERC721(address(dotnsRegistrar)).ownerOf(uint256(_nodeOf(BASE))), newcomer);
    }

    function test_gateway_reservation_clears_up_to_its_limit() public {
        uint256 bound = dotnsPopController.MAX_QUEUE_STEPS_PER_CALL();
        _queueExpired(bound);
        address newcomer = makeAddr("newcomer");
        _newcomerReserves(newcomer);

        (bool reserved, address holder) = dotnsPopController.isReservedForClaim(BASE);
        assertTrue(reserved);
        assertEq(holder, newcomer);
        (address popHolder,) = popRules.getBaseNameReservation(BASE);
        assertEq(popHolder, newcomer);
    }

    /// @dev The user at the front holds PopRules, so when they leave the queue is cleared to the
    ///      next user however many entries stand between them.
    function test_front_user_leaving_clears_the_queue_to_the_next_user() public {
        uint256 count = dotnsPopController.MAX_QUEUE_STEPS_PER_CALL() + 2;
        address[] memory users = new address[](count + 1);
        for (uint256 i; i < users.length; ++i) {
            users[i] = makeAddr(string.concat("user", vm.toString(i)));
            string memory stem =
                string.concat("member", string(abi.encodePacked(bytes1(uint8(0x61 + i)))));
            _reservePop(
                users[i], string.concat(stem, ".11"), _validChatKey(bytes1(uint8(i + 1))), BASE
            );
        }
        for (uint256 i = 1; i < count; ++i) {
            vm.prank(users[i]);
            dotnsPopController.relinquishReservation();
        }

        vm.prank(users[0]);
        dotnsPopController.relinquishReservation();

        (address popHolder,) = popRules.getBaseNameReservation(BASE);
        assertEq(popHolder, users[count], "PopRules moved to the next user");
    }

    /// @dev Indices never restart, so a pointer a claim left below the head can never match an
    ///      entry queued under the same label later.
    /// @dev A front user who leaves through a gateway call clears at most the gateway's limit,
    ///      so a long run behind them cannot push the call past the weight limit. PopRules keeps
    ///      naming them until a later call reaches an active user, which gains them nothing.
    function test_front_user_leaving_through_the_gateway_clears_at_most_the_limit() public {
        uint256 bound = dotnsPopController.MAX_QUEUE_STEPS_PER_CALL();
        address front = makeAddr("front");
        _reservePop(front, "frontuser.11", _validChatKey(0x01), BASE);
        address[] memory leavers = new address[](bound + 1);
        for (uint256 i; i < leavers.length; ++i) {
            leavers[i] = makeAddr(string.concat("leaver", vm.toString(i)));
            string memory stem =
                string.concat("leaver", string(abi.encodePacked(bytes1(uint8(0x61 + i)))));
            _reservePop(
                leavers[i], string.concat(stem, ".11"), _validChatKey(bytes1(uint8(i + 2))), BASE
            );
        }
        address waiter = makeAddr("waiter");
        _reservePop(waiter, "waiteruser.11", _validChatKey(0x66), BASE);
        for (uint256 i; i < leavers.length; ++i) {
            vm.prank(leavers[i]);
            dotnsPopController.relinquishReservation();
        }

        // `front` moves to another name through the gateway.
        _rootReservePersonhoodName(
            IDotnsPopController.PersonhoodNameReservation({user: front, label: "othername"})
        );

        bytes32 labelhash = keccak256(bytes(BASE));
        (uint64 head,) = dotnsPopController.reservationMeta(labelhash);
        assertEq(head, bound, "front's entry and the limit's worth of empty entries cleared");
        (address popHolder,) = popRules.getBaseNameReservation(BASE);
        assertEq(popHolder, front, "PopRules left as it was");
        assertEq(dotnsPopController.userReservation(front).labelhash, keccak256(bytes("othername")));
        vm.expectRevert(
            abi.encodeWithSelector(
                IPopRules.PopError.selector, "Reserved for a device-name holder's personhood claim"
            )
        );
        popRules.priceWithCheck(BASE, front);

        dotnsPopController.expireReservation(BASE);
        (popHolder,) = popRules.getBaseNameReservation(BASE);
        assertEq(popHolder, waiter, "the next clearing reaches the waiter");
    }

    function test_drained_queue_keeps_its_indices() public {
        uint256 count = 2;
        _queueExpired(count);
        dotnsPopController.expireReservation(BASE);

        bytes32 labelhash = keccak256(bytes(BASE));
        (uint64 head, uint64 tail) = dotnsPopController.reservationMeta(labelhash);
        assertEq(head, count);
        assertEq(tail, count);

        address newcomer = makeAddr("newcomer");
        _newcomerReserves(newcomer);
        assertEq(dotnsPopController.userReservation(newcomer).index, count);
    }

    function test_gateway_reservation_that_empties_the_queue_moves_the_slot_in_one_call() public {
        _queueExpired(dotnsPopController.MAX_QUEUE_STEPS_PER_CALL());
        address newcomer = makeAddr("newcomer");

        vm.recordLogs();
        _newcomerReserves(newcomer);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 labelhash = keccak256(bytes(BASE));
        (uint64 head, uint64 tail) = dotnsPopController.reservationMeta(labelhash);
        assertEq(tail - head, 1, "only the newcomer is queued");
        (bool reserved, address holder) = dotnsPopController.isReservedForClaim(BASE);
        assertTrue(reserved);
        assertEq(holder, newcomer);
        (address popHolder,) = popRules.getBaseNameReservation(BASE);
        assertEq(popHolder, newcomer, "PopRules moved to the newcomer");
        assertEq(dotnsPopController.reservedLabelOf(labelhash), BASE, "label kept");

        uint256 released;
        uint256 reservedEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(popRules)) continue;
            if (logs[i].topics[0] == IPopRules.BaseNameReleased.selector) ++released;
            if (logs[i].topics[0] == IPopRules.BaseNameReserved.selector) ++reservedEvents;
        }
        assertEq(released, 1, "one release");
        assertEq(reservedEvents, 1, "one reservation");
    }

    function test_expireReservation_clears_a_full_queue_in_one_call() public {
        uint256 full = dotnsPopController.MAX_RESERVATION_QUEUE();
        _queueExpired(full);
        bytes32 labelhash = keccak256(bytes(BASE));

        dotnsPopController.expireReservation(BASE);

        (uint64 head, uint64 tail) = dotnsPopController.reservationMeta(labelhash);
        assertEq(head, full);
        assertEq(tail, full);
        (address popHolder,) = popRules.getBaseNameReservation(BASE);
        assertEq(popHolder, address(0), "slot released once the queue empties");
        assertEq(bytes(dotnsPopController.reservedLabelOf(labelhash)).length, 0);
    }

    function test_prepareDeviceContainer_mints_a_soulbound_container_for_the_controller() public {
        bytes32 containerNode = _nodeOf("42");
        assertFalse(dotnsRegistrar.exists(uint256(containerNode)));

        vm.prank(makeAddr("stranger"));
        dotnsPopController.prepareDeviceContainer("42");

        assertTrue(dotnsRegistrar.exists(uint256(containerNode)));
        assertEq(dotnsRegistry.owner(containerNode), address(dotnsPopController));
        assertTrue(dotnsRegistrar.isSoulbound(uint256(containerNode)));

        // A second call is a no-op, and issuance uses the prepared container.
        dotnsPopController.prepareDeviceContainer("42");
        _reservePop(ed, "michael.42", _validChatKey(0x01), "");
        assertEq(dotnsRegistry.owner(_deviceNodeOf("michael.42")), ed);
    }

    function test_prepareDeviceContainer_rejects_a_suffix_that_is_not_two_digits() public {
        string[4] memory bad = ["4", "421", "4a", ""];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(IDotnsPopController.InvalidDeviceLabel.selector);
            dotnsPopController.prepareDeviceContainer(bad[i]);
        }
    }

    function test_prepareDeviceContainer_rejects_a_container_held_by_someone_else() public {
        bytes32 containerNode = _nodeOf("42");
        vm.startPrank(address(dotnsRegistrarController));
        dotnsRegistrar.register(uint256(containerNode), ed, "");
        dotnsRegistry.setOwner(containerNode, ed);
        vm.stopPrank();

        vm.expectRevert(IDotnsRegistry.NotAuthorised.selector);
        dotnsPopController.prepareDeviceContainer("42");
    }

    function test_issuance_records_a_container_it_did_not_mint_in_this_version() public {
        _reservePop(ed, "michael.42", _validChatKey(0x01), "");
        bytes32 containerNode = _nodeOf("42");

        // Forget the container, as a deployment upgraded from a version without the record would.
        bytes32 slot = keccak256(abi.encode(containerNode, uint256(10)));
        assertEq(uint256(vm.load(address(dotnsPopController), slot)), 1, "recorded on first use");
        vm.store(address(dotnsPopController), slot, bytes32(0));

        _reservePop(tiago, "matthew.42", _validChatKey(0x02), "");

        assertEq(dotnsRegistry.owner(_deviceNodeOf("matthew.42")), tiago);
        assertEq(uint256(vm.load(address(dotnsPopController), slot)), 1, "recorded again");
    }
}
