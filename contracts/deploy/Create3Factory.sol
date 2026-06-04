// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {CREATE3} from "solady/utils/CREATE3.sol";

/// @title Dotns CREATE3 Factory
/// @notice Permissionless wrapper around Solady's audited CREATE3 library.
/// @dev Anyone may call @custom:function deploy. CREATE3 addresses are a pure function of
/// `(factory_address, salt)` — the caller never enters the derivation — so caller-gating
/// would not strengthen address determinism. Salt-squatting griefing is in-scope for the
/// caller, not the factory: salts in the DotNS namespace (`CREATE3_SALT_NAMESPACE` in
/// `BaseDeployer`) get bumped end-to-end if a slot is ever found occupied. Keeping the
/// factory permissionless removes the cross-chain ownership-coordination burden and lets
/// CI keys, ops keys, and recovery flows all coexist without ownership transfers.
/// @custom:security-contact admin@parity.io
contract Create3Factory {
    /// @notice Emitted on every successful CREATE3 deployment through this factory.
    /// @dev `salt` and `deployed` are indexed so consumers can filter by either. `initCodeHash`
    /// is published alongside the deployment so downstream tooling can pin codehash
    /// expectations against the on-chain artefact without re-fetching bytecode.
    /// @param salt The CREATE3 salt used to derive the deployed address.
    /// @param deployed Address at which the contract was instantiated.
    /// @param initCodeHash `keccak256` of the init code passed to @custom:function deploy.
    /// @param value Native value forwarded to the constructor (zero for the dotNS pipeline).
    event Deployed(
        bytes32 indexed salt, address indexed deployed, bytes32 initCodeHash, uint256 value
    );

    /// @notice Thrown when @custom:function deploy is called with an empty `initCode` blob.
    /// @dev CREATE3 with empty init code would deploy a zero-byte contract at the predicted
    /// address; the factory rejects the call early so callers fail fast on a malformed
    /// artefact lookup rather than land a useless deployment.
    error EmptyInitCode();

    /// @notice Accepts native transfers so callers can pre-fund the factory if they want
    /// constructors that take `msg.value`.
    /// @dev The dotNS pipeline never forwards native value; this exists purely so the factory
    /// is compatible with payable-constructor callers from other consumers.
    receive() external payable {}

    /// @notice Deploys `initCode` at the deterministic address derived from `salt`.
    /// @dev Permissionless: any caller may invoke. The deployed address is
    /// `CREATE3.predictDeterministicAddress(salt)` and is independent of `msg.sender`. The
    /// call reverts if `initCode` is empty (@custom:reverts EmptyInitCode) or if the
    /// predicted slot is already occupied (Solady raises its own revert on collision). Emits
    /// @custom:emits Deployed on success. Native value attached to the call is forwarded to
    /// the new contract's constructor.
    /// @param salt CREATE3 salt; combined with this factory's address to derive the target.
    /// @param initCode Concatenation of creation bytecode and ABI-encoded constructor args.
    /// @return deployed Address of the newly deployed contract.
    function deploy(
        bytes32 salt,
        bytes calldata initCode
    )
        external
        payable
        returns (address deployed)
    {
        if (initCode.length == 0) revert EmptyInitCode();

        deployed = CREATE3.deployDeterministic(msg.value, initCode, salt);
        emit Deployed(salt, deployed, keccak256(initCode), msg.value);
    }

    /// @notice Returns the address that @custom:function deploy would target for `salt`.
    /// @dev Pure projection of `(factory_address, salt)` — does not check whether the address
    /// is currently occupied. Callers that need occupancy info should follow up with an
    /// `addr.code.length` check.
    /// @param salt CREATE3 salt to look up.
    /// @return predicted Address at which a @custom:function deploy call with this salt would
    /// instantiate.
    function predict(bytes32 salt) external view returns (address predicted) {
        predicted = CREATE3.predictDeterministicAddress(salt);
    }
}
