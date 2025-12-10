//SPDX-License-Identifier: MIT
pragma solidity ~0.8.17;

import "./IPriceOracle.sol";

interface IETHRegistrarController {
    /// TODO: This should be removed when PoP is available and replaced by a Origin call check
    /// @notice Individuality verification levels for domain registration
    /// @dev Determines which domain name patterns can be registered
    enum IndividualityType {
        NONE,                  // 9+ chars - first come, first served
        PERSON_LIGHT,          // 6+ chars + 2 digits - Light verification required
        PROOF_OF_PERSONHOOD,   // 6+ chars - Full personhood proof required
        GOVERNANCE             // <6 chars - Polkadot governance only
    }

    struct Registration {
        string label;
        address owner;
        uint256 duration;
        bytes32 secret;
        address resolver;
        bytes[] data;
        uint8 reverseRecord;
        bytes32 referrer;
        IndividualityType individualityType;
    }

    function rentPrice(
        string memory label,
        uint256 duration
    )
        external
        view
        returns (IPriceOracle.Price memory);

    function available(string memory label) external returns (bool);

    function makeCommitment(Registration memory registration)
        external
        pure
        returns (bytes32 commitment);

    function commit(bytes32 commitment) external;

    function register(Registration memory registration) external payable;

    function renew(string calldata label, uint256 duration, bytes32 referrer) external payable;
}
