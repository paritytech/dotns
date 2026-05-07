// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Partial vendor of paritytech/polkadot-sdk:
//   substrate/frame/revive/uapi/sol/ISystem.sol
// Only the members DotNS calls are kept; widen this interface if a future
// caller needs more of the upstream surface. Keep names and selectors in
// sync with upstream when bumping pallet-revive.

address constant SYSTEM_ADDR = 0x0000000000000000000000000000000000000900;

interface ISystem {
    /// Checks whether the caller of the contract calling this function is root.
    ///
    /// Note that only the origin of the call stack can be root. Hence this
    /// function returning `true` implies that the contract is being called by the origin.
    ///
    /// A return value of `true` indicates that this contract is being called by a root origin,
    /// and `false` indicates that the caller is a signed origin.
    function callerIsRoot() external view returns (bool);
}
