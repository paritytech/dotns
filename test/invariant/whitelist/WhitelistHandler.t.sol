// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {DotnsNameWhitelist} from "../../../contracts/whitelist/DotnsNameWhitelist.sol";
import {IDotnsNameWhitelist} from "../../../contracts/whitelist/IDotnsNameWhitelist.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";
import {ISystem} from "../../../contracts/external/revive/ISystem.sol";

/// @title WhitelistHandler
/// @notice Drives the whitelist through its lifecycle for the invariant suite, cycling a fixed
///         actor and label set and swallowing expected reverts so the fuzzer keeps exploring.
contract WhitelistHandler is Test {
    DotnsNameWhitelist public immutable WHITELIST;
    address public immutable OWNER;
    address public immutable CONTROLLER;
    address public immutable POP_CONTROLLER;

    address[] internal _actors;
    string[] internal _labels;

    constructor(
        DotnsNameWhitelist whitelist,
        address owner,
        address controller,
        address popController,
        address[] memory actors
    ) {
        WHITELIST = whitelist;
        OWNER = owner;
        CONTROLLER = controller;
        POP_CONTROLLER = popController;
        _actors = actors;
        _labels.push("alicebob");
        _labels.push("wonderla");
        _labels.push("carolboy");
        _labels.push("danielle");
    }

    function labelCount() external view returns (uint256 count) {
        return _labels.length;
    }

    function labelAt(uint256 index) external view returns (string memory label) {
        return _labels[index];
    }

    function request(uint256 actorSeed, uint256 labelSeed) external {
        address user = _actor(actorSeed);
        vm.prank(user);
        try WHITELIST.requestName(_label(labelSeed), "reason", user) {} catch {}
    }

    function accept(uint256 labelSeed) external {
        string memory label = _label(labelSeed);
        if (WHITELIST.claimantCount(label) == 0) {
            return;
        }
        address user = WHITELIST.claims(label, 0, 1)[0].user;
        _asRoot();
        try WHITELIST.accept(label, user) {} catch {}
        _asSigned();
    }

    function reject(uint256 labelSeed) external {
        string memory label = _label(labelSeed);
        if (WHITELIST.claimantCount(label) == 0) {
            return;
        }
        address user = WHITELIST.claims(label, 0, 1)[0].user;
        _asRoot();
        try WHITELIST.reject(label, user) {} catch {}
        _asSigned();
    }

    function grant(uint256 actorSeed, uint256 labelSeed) external {
        _asRoot();
        try WHITELIST.grantName(_label(labelSeed), _actor(actorSeed)) {} catch {}
        _asSigned();
    }

    function revoke(uint256 labelSeed) external {
        _asRoot();
        try WHITELIST.revokeName(_label(labelSeed)) {} catch {}
        _asSigned();
    }

    function setReserved(uint256 labelSeed, bool reserved) external {
        _asRoot();
        try WHITELIST.setReserved(_label(labelSeed), reserved) {} catch {}
        _asSigned();
    }

    function consume(uint256 labelSeed, bool viaPop) external {
        string memory label = _label(labelSeed);
        address winner = WHITELIST.granteeOf(label);
        if (winner == address(0)) {
            return;
        }
        vm.prank(viaPop ? POP_CONTROLLER : CONTROLLER);
        try WHITELIST.consume(label, winner) {} catch {}
    }

    function tuneMaxClaimants(uint256 seed) external {
        uint16 newMax = uint16(1 + (seed % DotnsConstants.WHITELIST_MAX_CLAIMANTS_LIMIT));
        _asRoot();
        try WHITELIST.setMaxClaimants(newMax) {} catch {}
        _asSigned();
    }

    function _actor(uint256 seed) internal view returns (address actor) {
        return _actors[seed % _actors.length];
    }

    function _label(uint256 seed) internal view returns (string memory label) {
        return _labels[seed % _labels.length];
    }

    /// @notice Puts the next call under a substrate Root origin. The whitelist's admin surface is
    /// Root-only, so every governance action here needs it; a plain prank produces a Signed origin
    /// and would revert into the catch, leaving the campaign to exercise only the permissionless
    /// entry points.
    function _asRoot() internal {
        _mockOriginIsRoot(true);
    }

    /// @notice Restores the default. `DotnsRegistrarController.registerReserved` reads
    /// `originIsRoot` too, and handler state is campaign-scoped, so a sticky `true` would put a
    /// later reserved registration on the Root branch.
    function _asSigned() internal {
        _mockOriginIsRoot(false);
    }

    function _mockOriginIsRoot(bool returnValue) internal {
        vm.mockCall(
            DotnsConstants.REVIVE_SYSTEM,
            abi.encodeWithSelector(ISystem.originIsRoot.selector),
            abi.encode(returnValue)
        );
    }
}
