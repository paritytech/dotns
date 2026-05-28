// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title Create2Factory
/// @notice Minimal singleton CREATE2 factory used by the DotNS deploy pipeline
///         to give every protocol contract the same address on every chain.
/// @dev Determinism rests on three things, all enforced by the deploy
///      pipeline rather than this contract:
///        1. The factory itself must live at the same address on every chain.
///           That holds when the same deployer EOA broadcasts the factory
///           constructor as its first transaction (nonce 0) on each chain —
///           `address = keccak256(rlp([sender, nonce]))[12:]` depends only on
///           the EOA and the nonce, so a fresh deployer hitting nonce 0 lands
///           on the same factory address everywhere.
///        2. Every downstream init code is constructor-arg-stable across
///           chains. Implementations have no constructor args so they are
///           trivially identical; ERC1967 proxies take `(impl, initData)`,
///           which is stable as long as `impl` and every address embedded in
///           `initData` is itself CREATE2-derived through this factory.
///        3. The salt for each contract is fixed per role + version.
/// @custom:security-contact admin@parity.io
contract Create2Factory {
    /// @notice Emitted whenever a contract is successfully deployed by this
    ///         factory. `salt` and `addr` together let consumers reconcile a
    ///         deploy run against expected per-role addresses.
    /// @param addr Deployed contract address.
    /// @param salt Salt the caller passed in.
    event Deployed(address indexed addr, bytes32 indexed salt);

    /// @notice Deploys `initCode` under `salt` via CREATE2 and returns the
    ///         resulting address.
    /// @dev The factory itself is the CREATE2 sender, so two callers passing
    ///      the same `(salt, initCode)` collide on the same address — which
    ///      is exactly the point. The second deploy reverts because CREATE2
    ///      cannot overwrite existing code.
    /// @param salt Caller-chosen salt. Convention is
    ///        `keccak256("dotns:<role>:v<version>")`.
    /// @param initCode Creation bytecode plus ABI-encoded constructor args.
    /// @return addr Address of the freshly deployed contract.
    function deploy(bytes32 salt, bytes memory initCode) external returns (address addr) {
        assembly ("memory-safe") {
            addr := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(addr != address(0), "Create2Factory: deploy failed");
        emit Deployed(addr, salt);
    }

    /// @notice Precomputes the address `deploy(salt, initCode)` would yield
    ///         under this factory. Useful for sanity-checking before broadcast
    ///         and for cross-chain address verification scripts.
    /// @param salt Salt the caller would pass.
    /// @param initCodeHash `keccak256(initCode)` — caller hashes their own
    ///        init code so this helper stays calldata-cheap.
    /// @return The address the deploy would land at.
    function computeAddress(bytes32 salt, bytes32 initCodeHash) external view returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash))
                )
            )
        );
    }
}
