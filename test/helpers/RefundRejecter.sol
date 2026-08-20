// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @title RefundRejecter
/// @notice ERC721 receiver that reverts on every inbound native transfer so the
///         controller's overpayment path can be proven to credit the
///         pull-payment ledger instead of pushing to a brittle receiver.
contract RefundRejecter is IERC721Receiver {
    /// @notice Thrown whenever the receiver is sent native value.
    error RefundsNotAccepted();

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

    /// @notice Reverts on every inbound native transfer.
    receive() external payable {
        revert RefundsNotAccepted();
    }
}
