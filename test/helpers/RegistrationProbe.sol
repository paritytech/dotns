// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @title RegistrationProbe
/// @notice ERC721 receiver that snapshots controller-side state from inside
///         `onERC721Received` so reclaim-callback tests can assert the
///         registry is wired to the new owner before custody moves.
contract RegistrationProbe is IERC721Receiver {
    /// @notice Forward registry the probe queries during the callback.
    address public registry;
    /// @notice Reverse resolver the probe queries during the callback.
    address public reverseResolver;
    /// @notice Forward-registry owner observed inside `onERC721Received`.
    address public observedRegistryOwner;
    /// @notice Reverse name observed inside `onERC721Received` for the probe itself.
    string public observedReverseName;
    /// @notice Set to true on the first entry into `onERC721Received`.
    bool public callbackFired;

    /// @notice Wires the probe to the sibling addresses it will read during the callback.
    constructor(address _registry, address _reverseResolver) {
        registry = _registry;
        reverseResolver = _reverseResolver;
    }

    /// @inheritdoc IERC721Receiver
    function onERC721Received(
        address,
        address,
        uint256 tokenId,
        bytes calldata
    )
        external
        override
        returns (bytes4)
    {
        callbackFired = true;
        (bool ok, bytes memory data) =
            registry.staticcall(abi.encodeWithSignature("owner(bytes32)", bytes32(tokenId)));
        if (ok) observedRegistryOwner = abi.decode(data, (address));
        (ok, data) =
            reverseResolver.staticcall(abi.encodeWithSignature("nameOf(address)", address(this)));
        if (ok) observedReverseName = abi.decode(data, (string));
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Accepts native refunds credited by the controller's overpayment path.
    receive() external payable {}
}
