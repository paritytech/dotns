// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {DotnsNameWhitelist} from "../../../contracts/whitelist/DotnsNameWhitelist.sol";
import {IDotnsNameWhitelist} from "../../../contracts/whitelist/IDotnsNameWhitelist.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";
import {StringUtils} from "../../../contracts/utils/StringUtils.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @title DotnsNameWhitelist fuzz tests
/// @notice Exercises claiming, competing claims, resolution and the reason bound over fuzzed
///         inputs.
contract DotnsNameWhitelistFuzz is BaseDotns {
    DotnsNameWhitelist internal whitelist;

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
        vm.stopPrank();

        // Configuration is Root-only, and the suite's own actions are governance calls, so it
        // runs under a Root origin throughout.
        // The suite calls governance entry points directly, so it runs under a Root origin
        // throughout rather than mocking per call.
        _mockOriginIsRoot(true);
        whitelist.setWindow(0, 365 days);
    }

    function _label(uint256 seed) internal pure returns (string memory) {
        uint256 value = seed % 100;
        string memory suffix = value < 10
            ? string.concat("0", StringUtils.uintToString(value))
            : StringUtils.uintToString(value);
        return string.concat("fuzzname", suffix);
    }

    function testFuzz_requestName_records(uint256 seed, address user) public {
        vm.assume(user != address(0));
        string memory label = _label(seed);
        vm.prank(user);
        whitelist.requestName(label, "reason", user);

        IDotnsNameWhitelist.Claim memory claim = whitelist.claimOf(label, user);
        assertEq(claim.user, user);
        assertEq(uint256(claim.status), uint256(IDotnsNameWhitelist.ClaimStatus.Requested));
        assertEq(whitelist.claimantCount(label), 1);
    }

    function testFuzz_competing_claims_do_not_collide(
        uint256 seed,
        address first,
        address second
    )
        public
    {
        vm.assume(first != address(0) && second != address(0) && first != second);
        string memory label = _label(seed);
        vm.prank(first);
        whitelist.requestName(label, "first", first);
        vm.prank(second);
        whitelist.requestName(label, "second", second);
        assertEq(whitelist.claimantCount(label), 2);
    }

    function testFuzz_accept_yields_single_winner(
        uint256 seed,
        address first,
        address second
    )
        public
    {
        vm.assume(first != address(0) && second != address(0) && first != second);
        string memory label = _label(seed);
        vm.prank(first);
        whitelist.requestName(label, "first", first);
        vm.prank(second);
        whitelist.requestName(label, "second", second);

        vm.prank(owner);
        whitelist.accept(label, first);

        assertEq(whitelist.granteeOf(label), first);
        assertFalse(whitelist.isGrantedTo(label, second));
        assertEq(whitelist.claimantCount(label), 0);
    }

    function testFuzz_reject_never_reserves(uint256 seed, address user) public {
        vm.assume(user != address(0));
        string memory label = _label(seed);
        vm.prank(user);
        whitelist.requestName(label, "r", user);
        vm.prank(owner);
        whitelist.reject(label, user);

        assertEq(whitelist.granteeOf(label), address(0));
        assertEq(uint256(whitelist.statusOf(label)), uint256(IDotnsNameWhitelist.NameStatus.Open));
    }

    function testFuzz_reason_length_bound(uint256 seed, uint256 length) public {
        length = bound(length, 0, 512);
        string memory reason = string(new bytes(length));
        string memory label = _label(seed);

        if (length > whitelist.maxReasonBytes()) {
            vm.expectRevert(IDotnsNameWhitelist.ReasonTooLong.selector);
            vm.prank(ed);
            whitelist.requestName(label, reason, ed);
        } else {
            vm.prank(ed);
            whitelist.requestName(label, reason, ed);
            assertEq(whitelist.claimOf(label, ed).reason, reason);
        }
    }

    function testFuzz_requestName_reverts_after_window_closes(
        uint256 seed,
        uint64 duration
    )
        public
    {
        duration = uint64(bound(uint256(duration), 1, 3650 days));
        string memory label = _label(seed);
        vm.prank(owner);
        whitelist.setWindow(0, duration);
        vm.warp(block.timestamp + duration);

        vm.expectRevert(IDotnsNameWhitelist.WindowClosed.selector);
        vm.prank(ed);
        whitelist.requestName(label, "r", ed);
    }
}
