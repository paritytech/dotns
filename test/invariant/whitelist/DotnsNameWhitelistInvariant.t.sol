// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {WhitelistHandler} from "./WhitelistHandler.t.sol";
import {DotnsNameWhitelist} from "../../../contracts/whitelist/DotnsNameWhitelist.sol";
import {IDotnsNameWhitelist} from "../../../contracts/whitelist/IDotnsNameWhitelist.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @title DotnsNameWhitelist invariants
/// @notice Drives the whitelist through random lifecycle sequences and asserts the name and claim
///         guarantees hold at every step.
contract DotnsNameWhitelistInvariant is BaseDotns {
    DotnsNameWhitelist internal whitelist;
    WhitelistHandler internal handler;

    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);
        whitelist = DotnsNameWhitelist(
            Upgrades.deployUUPSProxy(
                "DotnsNameWhitelist.sol:DotnsNameWhitelist",
                abi.encodeCall(
                    DotnsNameWhitelist.initialize,
                    (owner, IDotnsProtocolRegistry(address(protocolRegistry)))
                )
            )
        );
        _mockOriginIsRoot(true);
        whitelist.setWindow(0, 3650 days);
        _mockOriginIsRoot(false);
        vm.stopPrank();

        address[] memory actors = new address[](4);
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("wlActor", vm.toString(i)));
        }

        handler = new WhitelistHandler(
            whitelist,
            owner,
            protocolRegistry.get(DotnsConstants.CONTROLLER),
            protocolRegistry.get(DotnsConstants.POP_CONTROLLER),
            actors
        );
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.request.selector;
        selectors[1] = handler.accept.selector;
        selectors[2] = handler.reject.selector;
        selectors[3] = handler.grant.selector;
        selectors[4] = handler.revoke.selector;
        selectors[5] = handler.setReserved.selector;
        selectors[6] = handler.consume.selector;
        selectors[7] = handler.tuneMaxClaimants.selector;
        selectors[8] = handler.elapse.selector;
        selectors[9] = handler.tuneGrantDuration.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice A name reports a winner exactly when it is `Claimed`.
    function invariant_winner_iff_claimed() public view {
        uint256 n = handler.labelCount();
        for (uint256 i; i < n; ++i) {
            string memory label = handler.labelAt(i);
            bool claimed = whitelist.statusOf(label) == IDotnsNameWhitelist.NameStatus.Claimed;
            assertEq(whitelist.granteeOf(label) != address(0), claimed);
        }
    }

    /// @notice A claimed name holds no live claims, and no name exceeds the hard claimant ceiling.
    /// @dev Asserts against the ceiling rather than the live `maxClaimants`, since governance may
    ///      lower the cap below counts admitted under an earlier, higher cap.
    function invariant_claim_bounds() public view {
        uint256 n = handler.labelCount();
        for (uint256 i; i < n; ++i) {
            string memory label = handler.labelAt(i);
            uint256 count = whitelist.claimantCount(label);
            assertLe(count, DotnsConstants.WHITELIST_MAX_CLAIMANTS_LIMIT);
            if (whitelist.statusOf(label) == IDotnsNameWhitelist.NameStatus.Claimed) {
                assertEq(count, 0);
            }
        }
    }

    /// @notice Every active name is stored as reserved or claimed, or holds claims.
    /// @dev Reads the stored status: a lapsed grant stays in the set, reading Open, until a write
    ///      on the name clears it. That is the only way an active name may read Open with no
    ///      claims, and `invariant_a_lapsed_grant_is_past_its_expiry` pins it down.
    function invariant_active_set_is_consistent() public view {
        uint256 count = whitelist.nameCount();
        IDotnsNameWhitelist.NameView[] memory page = whitelist.names(0, count == 0 ? 1 : count);
        assertEq(page.length, count);
        for (uint256 i; i < page.length; ++i) {
            IDotnsNameWhitelist.NameView memory entry = page[i];
            (IDotnsNameWhitelist.NameStatus stored, address winner,) = _storedRecord(entry.label);
            bool active = stored != IDotnsNameWhitelist.NameStatus.Open
                || whitelist.claimantCount(entry.label) != 0;
            assertTrue(active, "an active name holds no state");
            // Guards the `_names` slot decode: a name the view reads as Claimed or Reserved is
            // stored that way, with the winner the view reports.
            if (entry.status != IDotnsNameWhitelist.NameStatus.Open) {
                assertEq(uint256(stored), uint256(entry.status), "slot 2 layout");
                assertEq(winner, entry.winner, "slot 2 layout");
            }
        }
    }

    /// @notice A name stored as `Claimed` reads Open only once its grant period has passed.
    function invariant_a_lapsed_grant_is_past_its_expiry() public view {
        (uint64 duration, uint64 clockStart) = _grantConfig();
        uint256 n = handler.labelCount();
        for (uint256 i; i < n; ++i) {
            string memory label = handler.labelAt(i);
            (IDotnsNameWhitelist.NameStatus stored, address winner, uint64 grantedAt) =
                _storedRecord(label);
            if (stored != IDotnsNameWhitelist.NameStatus.Claimed) continue;

            uint64 start = grantedAt < clockStart ? clockStart : grantedAt;
            bool live = block.timestamp < start + duration;
            assertEq(
                whitelist.statusOf(label) == IDotnsNameWhitelist.NameStatus.Claimed,
                live,
                "a stored grant reads Claimed exactly while its period runs"
            );
            assertEq(whitelist.granteeOf(label), live ? winner : address(0));
            assertEq(whitelist.isGrantedTo(label, winner), live);
            assertEq(whitelist.grantExpiresAt(label), live ? start + duration : 0);
        }
    }

    /// @dev Decodes the first slot of a name's record: status (byte 0), winner (bytes 1-20) and
    ///      grantedAt (bytes 21-28). `_names` sits at slot 2.
    function _storedRecord(string memory label)
        internal
        view
        returns (IDotnsNameWhitelist.NameStatus status, address winner, uint64 grantedAt)
    {
        uint256 word = uint256(
            vm.load(address(whitelist), keccak256(abi.encode(_nodeOf(label), uint256(2))))
        );
        // Each cast keeps exactly the field's bits after the shift.
        // forge-lint: disable-next-line(unsafe-typecast)
        status = IDotnsNameWhitelist.NameStatus(uint8(word));
        // forge-lint: disable-next-line(unsafe-typecast)
        winner = address(uint160(word >> 8));
        // forge-lint: disable-next-line(unsafe-typecast)
        grantedAt = uint64(word >> 168);
    }

    /// @dev Reads `grantDuration` and the grant clock start from slot 7, above the window.
    function _grantConfig() internal view returns (uint64 duration, uint64 clockStart) {
        uint256 word = uint256(vm.load(address(whitelist), bytes32(uint256(7))));
        // forge-lint: disable-next-line(unsafe-typecast)
        duration = uint64(word >> 128);
        // forge-lint: disable-next-line(unsafe-typecast)
        clockStart = uint64(word >> 192);
        assertEq(duration, whitelist.grantDuration(), "slot 7 layout");
    }
}
