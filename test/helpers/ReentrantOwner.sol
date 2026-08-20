// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IDotnsRegistrarController} from "../../contracts/registrars/IDotnsRegistrarController.sol";

/// @title ReentrantOwner
/// @notice ERC721 receiver that re-enters `register` from inside
///         `onERC721Received` so the transient non-reentrancy guard can be
///         pinned down against the reclaim path's `safeTransferFrom`.
contract ReentrantOwner is IERC721Receiver {
    /// @notice Controller the receiver re-enters on the callback.
    IDotnsRegistrarController public immutable CONTROLLER;
    /// @notice Registration payload the receiver replays inside `onERC721Received`.
    IDotnsRegistrarController.Registration public registration;

    /// @notice Binds the receiver to the controller it will attempt to re-enter.
    constructor(IDotnsRegistrarController controller) {
        CONTROLLER = controller;
    }

    /// @notice Stores the registration payload the receiver will replay inside the callback.
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
        override
        returns (bytes4)
    {
        CONTROLLER.register{value: 0}(registration);
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Accepts native refunds credited by the controller's overpayment path.
    receive() external payable {}
}
