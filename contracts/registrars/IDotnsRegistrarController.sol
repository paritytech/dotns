// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IDotnsRegistry} from "../registry/IDotnsRegistry.sol";

/// @title DotNS Registrar Controller Interface
/// @notice Interface for registering .dot labels using a commit–reveal scheme.
/// @dev This interface defines allocation only. Forward resolution, reverse lookup, pricing mechanics,
///      PoP validation, and store writing are handled by external contracts.
///
/// @dev Commit–reveal:
///      - Users commit a hash of registration parameters.
///      - After a minimum delay, they reveal the same parameters to register.
///
/// @dev Store writing:
///      - Implementations write the successfully registered name into the user’s Store
///        to create an immutable onchain record of the name registration.
///      - This store serves as a quick lookup for all names registered
/// @custom:security-contact admin@parity.io
interface IDotnsRegistrarController {
    /// @notice Parameters used to generate and reveal a commitment.
    /// @dev All fields must match exactly between commitment and reveal.
    /// @param label Label being registered (e.g. "alice").
    /// @param owner Address that will own the registered name.
    /// @param secret Secret used to bind the commitment.
    /// @param reserved Whether the name is reserved, This means the name is the default
    ///        name assigned that resolvers will point to.
    struct Registration {
        string label;
        address owner;
        bytes32 secret;
        bool reserved;
    }

    /// @notice Emitted when a commitment is submitted.
    /// @param commitment Commitment hash.
    event NameCommitted(bytes32 indexed commitment);

    /// @notice Emitted when a name is successfully registered.
    /// @param label Registered label.
    /// @param labelhash Keccak256 hash of the label.
    /// @param owner Owner of the name.
    /// @param baseCost The price returned by the oracle for this registration.
    /// @param store The Store instance used to persist an immutable registration record.
    event NameRegistered(
        string indexed label,
        bytes32 indexed labelhash,
        address indexed owner,
        uint256 baseCost,
        address store
    );

    /// @notice Thrown when an unexpired commitment already exists.
    /// @param commitment Commitment hash.
    error UnexpiredCommitmentExists(bytes32 commitment);

    /// @notice Thrown when revealing a commitment that does not exist.
    /// @param commitment Commitment hash.
    error CommitmentNotFound(bytes32 commitment);

    /// @notice Thrown when a commitment is revealed before the minimum age.
    /// @param commitment Commitment hash.
    /// @param minTime Earliest timestamp at which reveal is allowed.
    /// @param currentTime Current block timestamp.
    error CommitmentTooNew(bytes32 commitment, uint256 minTime, uint256 currentTime);

    /// @notice Thrown when a commitment has expired.
    /// @param commitment Commitment hash.
    /// @param maxTime Latest timestamp at which reveal is allowed.
    /// @param currentTime Current block timestamp.
    error CommitmentTooOld(bytes32 commitment, uint256 maxTime, uint256 currentTime);

    /// @notice Thrown when attempting to register an unavailable name.
    /// @param label Label supplied by the caller.
    error NameNotAvailable(string label);

    /// @notice Thrown when supplied payment is insufficient.
    error InsufficientValue();

    /// @notice Thrown when refund fails.
    error RefundFailed();

    /// @notice Thrown when max commitment age is invalid (must be > minCommitmentAge).
    error MaxCommitmentAgeTooLow();

    /// @notice Thrown when max commitment age is invalid (exceeds implementation limit).
    error MaxCommitmentAgeTooHigh();

    /// @notice Thrown when an invalid Store instance is encountered.
    /// @dev This usually means the store has not been deployed for the user.
    error InvalidStore();

    /// @notice Thrown when the caller is not the registry.
    error NotRegistry();

    /// @notice Returns whether a label is available for registration.
    /// @param label Label to check.
    /// @return isAvailable True if the label can be registered.
    function available(string calldata label) external view returns (bool isAvailable);

    /// @notice Computes the commitment hash for a registration.
    /// @param registration Registration parameters.
    /// @return commitment Commitment hash.
    function makeCommitment(Registration calldata registration)
        external
        pure
        returns (bytes32 commitment);

    /// @notice Submits a commitment for a future registration.
    /// @param commitment Commitment hash produced by makeCommitment.
    function commit(bytes32 commitment) external;

    /// @notice Registers a name after the commitment delay.
    /// @dev Registration parameters must match the committed values.
    /// @param registration Registration parameters.
    function register(Registration calldata registration) external payable;

    /// @notice Registers a name after the commitment delay.
    /// @dev Registration parameters must match the committed values.
    /// @dev Can only be called by owner
    /// @param registration Registration parameters.
    function registerReserved(Registration calldata registration) external;

    /// @notice Writes a newly created subnode to the user's Store.
    /// @dev This function is intended to be called **only by the registry**.
    /// @dev  Writes the computed `<sub>.<parent>.dot` value into the Store owned by `record.owner`.
    ///      It updates the user's Store with the subnode information so that all subnodes
    ///      for a user can be queried in real-time.
    ///      The Store must already exist for the `newOwner`. If the Store write fails, the call should revert.
    /// @param record SubnodeRecord to write to the Store.
    function writeSubnodeToStore(IDotnsRegistry.SubnodeRecord calldata record) external;
}
