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
                    (IDotnsProtocolRegistry(address(protocolRegistry)))
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

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.request.selector;
        selectors[1] = handler.accept.selector;
        selectors[2] = handler.reject.selector;
        selectors[3] = handler.grant.selector;
        selectors[4] = handler.revoke.selector;
        selectors[5] = handler.setReserved.selector;
        selectors[6] = handler.consume.selector;
        selectors[7] = handler.tuneMaxClaimants.selector;
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

    /// @notice Every active name is reserved, claimed, or holding claims.
    function invariant_active_set_is_consistent() public view {
        uint256 count = whitelist.nameCount();
        IDotnsNameWhitelist.NameView[] memory page = whitelist.names(0, count == 0 ? 1 : count);
        assertEq(page.length, count);
        for (uint256 i; i < page.length; ++i) {
            IDotnsNameWhitelist.NameView memory entry = page[i];
            bool active = entry.status != IDotnsNameWhitelist.NameStatus.Open
                || whitelist.claimantCount(entry.label) != 0;
            assertTrue(active);
        }
    }
}
