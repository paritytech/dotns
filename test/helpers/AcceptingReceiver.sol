// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @title AcceptingReceiver
/// @notice ERC721 receiver that silently accepts every inbound native transfer
///         so the controller's overpayment push path can be proven to credit
///         contract receivers directly without falling back to the pull ledger.
contract AcceptingReceiver is IERC721Receiver {
    /// @notice Cumulative native value forwarded into `receive`.
    uint256 public received;

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

    /// @notice Silently accepts inbound native transfers and tallies them.
    receive() external payable {
        received += msg.value;
    }
}
