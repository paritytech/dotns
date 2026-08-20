// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IDotnsRegistrarController} from "../../contracts/registrars/IDotnsRegistrarController.sol";

/// @title ReentrantOverpaymentAttacker
/// @notice Contract receiver that re-enters the controller from inside
///         `receive` so the transient non-reentrancy guard rejects the inbound
///         push and the controller is forced down the pull-payment fallback.
contract ReentrantOverpaymentAttacker is IERC721Receiver {
    /// @notice Controller the attacker tries to re-enter on inbound refunds.
    IDotnsRegistrarController public immutable CONTROLLER;
    /// @notice Registration payload replayed inside `receive`.
    IDotnsRegistrarController.Registration public registration;

    /// @notice Binds the attacker to the controller it tries to re-enter.
    constructor(IDotnsRegistrarController controller) {
        CONTROLLER = controller;
    }

    /// @notice Arms the attacker with a registration payload it will replay inside `receive`.
    function arm(IDotnsRegistrarController.Registration calldata payload) external {
        registration = payload;
    }

    /// @inheritdoc IERC721Receiver
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    )
        external
        pure
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Re-enters `register` from inside the overpayment push so the
    ///         transient guard reverts and the controller falls back to the
    ///         pull-payment ledger.
    receive() external payable {
        CONTROLLER.register{value: 0}(registration);
    }
}
