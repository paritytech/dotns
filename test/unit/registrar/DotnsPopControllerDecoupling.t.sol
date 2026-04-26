// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

/// @title Decoupling invariant for the dedicated PoP controller
/// @notice Pins the architectural claim made in `DotnsPopController.sol`:
///         neither the PoP controller nor the public commit-reveal controller
///         imports the other. A future refactor that adds such an import would
///         silently recouple the two flows; this test fails the build if that
///         happens. Lives at the source-file level because this is a textual
///         invariant, not a behavioural one.
contract DotnsPopControllerDecouplingTest is Test {
    string internal constant POP_CONTROLLER_PATH = "contracts/registrars/DotnsPopController.sol";
    string internal constant REGISTRAR_CONTROLLER_PATH =
        "contracts/registrars/DotnsRegistrarController.sol";

    function test_popController_does_not_import_commit_reveal_controller() public view {
        string memory source = vm.readFile(POP_CONTROLLER_PATH);
        assertFalse(
            _contains(source, "import {IDotnsRegistrarController}"),
            "DotnsPopController must not import IDotnsRegistrarController"
        );
        assertFalse(
            _contains(source, "import {DotnsRegistrarController}"),
            "DotnsPopController must not import DotnsRegistrarController"
        );
    }

    function test_commitReveal_controller_does_not_import_pop_controller() public view {
        string memory source = vm.readFile(REGISTRAR_CONTROLLER_PATH);
        assertFalse(
            _contains(source, "import {IDotnsPopController}"),
            "DotnsRegistrarController must not import IDotnsPopController"
        );
        assertFalse(
            _contains(source, "import {DotnsPopController}"),
            "DotnsRegistrarController must not import DotnsPopController"
        );
    }

    // Naive substring search. Solidity 0.8 has no standard `contains`, so we
    // walk the haystack once comparing fixed-width windows. Only used on
    // 10-20 KB source files at test time; no gas concern.
    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory haystackBytes = bytes(haystack);
        bytes memory needleBytes = bytes(needle);
        if (needleBytes.length == 0 || haystackBytes.length < needleBytes.length) {
            return needleBytes.length == 0;
        }
        uint256 limit = haystackBytes.length - needleBytes.length + 1;
        for (uint256 i = 0; i < limit; i++) {
            bool match_ = true;
            for (uint256 j = 0; j < needleBytes.length; j++) {
                if (haystackBytes[i + j] != needleBytes[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) return true;
        }
        return false;
    }
}
