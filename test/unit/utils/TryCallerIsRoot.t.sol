// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";
import {SystemUtils} from "../../../contracts/utils/SystemUtils.sol";

contract TryCallerIsRootHarness {
    function tryCallerIsRoot() external view returns (bool root) {
        return SystemUtils.tryCallerIsRoot();
    }
}

contract AnswersTrue {
    function callerIsRoot() external pure returns (bool) {
        return true;
    }
}

contract AnswersFalse {
    function callerIsRoot() external pure returns (bool) {
        return false;
    }
}

contract Reverts {
    function callerIsRoot() external pure returns (bool) {
        revert("down");
    }
}

contract ReturnsNothing {
    fallback() external {}
}

/// @notice Answers a 32-byte word that is not a valid bool.
contract ReturnsTwo {
    fallback() external {
        assembly {
            mstore(0, 2)
            return(0, 32)
        }
    }
}

/// @notice Answers a word that decodes as true, followed by extra bytes.
contract ReturnsLongTrue {
    fallback() external {
        assembly {
            mstore(0, 1)
            mstore(32, 1)
            return(0, 64)
        }
    }
}

/// @notice Answers fewer than 32 bytes.
contract ReturnsShort {
    fallback() external {
        assembly {
            mstore(0, shl(248, 1))
            return(0, 1)
        }
    }
}

/// @notice `tryCallerIsRoot` answers true only for a well-formed true from the System precompile,
///         and any other answer either reads as false or reverts.
contract TryCallerIsRootTests is Test {
    TryCallerIsRootHarness private harness;

    function setUp() public {
        harness = new TryCallerIsRootHarness();
    }

    function test_answers_false_without_a_precompile() public {
        vm.etch(DotnsConstants.REVIVE_SYSTEM, "");
        assertFalse(harness.tryCallerIsRoot());
    }

    function test_answers_the_precompile() public {
        vm.etch(DotnsConstants.REVIVE_SYSTEM, address(new AnswersTrue()).code);
        assertTrue(harness.tryCallerIsRoot());

        vm.etch(DotnsConstants.REVIVE_SYSTEM, address(new AnswersFalse()).code);
        assertFalse(harness.tryCallerIsRoot());
    }

    function test_answers_false_when_the_precompile_reverts() public {
        vm.etch(DotnsConstants.REVIVE_SYSTEM, address(new Reverts()).code);
        assertFalse(harness.tryCallerIsRoot());
    }

    function test_answers_false_for_empty_return_data() public {
        vm.etch(DotnsConstants.REVIVE_SYSTEM, address(new ReturnsNothing()).code);
        assertFalse(harness.tryCallerIsRoot());
    }

    function test_answers_false_for_return_data_of_the_wrong_length() public {
        vm.etch(DotnsConstants.REVIVE_SYSTEM, address(new ReturnsLongTrue()).code);
        assertFalse(harness.tryCallerIsRoot());

        vm.etch(DotnsConstants.REVIVE_SYSTEM, address(new ReturnsShort()).code);
        assertFalse(harness.tryCallerIsRoot());
    }

    function test_revert_on_a_word_that_is_not_a_bool() public {
        vm.etch(DotnsConstants.REVIVE_SYSTEM, address(new ReturnsTwo()).code);
        vm.expectRevert();
        harness.tryCallerIsRoot();
    }
}
