// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";

import {WireDeployments} from "./WireDeployments.s.sol";

/// @title DeclareRelease
/// @notice Re-declares, on chain, what code each well-known key is expected to execute and which
///         release the network runs. Run once, after every implementation swap has verified.
/// @dev The declaration half of `WireDeployments`, without the wiring half. A fresh deploy wires
///      the keys and declares in one pass; an in-place upgrade moves the code behind keys that are
///      already wired, so it needs the declarations refreshed and nothing else. Extending the
///      pipeline rather than restating its key list is deliberate: a release that adds a key would
///      otherwise be declared by a fresh deploy and silently skipped by every upgrade, and the
///      resulting gap reads as drift with no way to tell it from an unauthorised swap.
///
///      The codehashes come from the chain, not from the build. Declaring from artefacts would
///      let a swap that silently did not happen be papered over by a declaration saying it did.
///
///      Ordering carries the same rule the checklist states for any network: the version is a
///      claim about the whole deployment, so it is written last and only once every key has been
///      declared. A run abandoned half way leaves the previous version standing, which clients
///      read as an older network rather than as a false new one.
/// @custom:security-contact admin@parity.io
contract DeclareRelease is WireDeployments {
    /// @notice Declares every key's codehash, verifies the deployment, then declares the release.
    /// @dev `DOTNS_RELEASE_TAG` is the bare semver the registry stores, for example `0.8.0`. It is
    ///      read before anything is broadcast, so a run that could not declare its release at the
    ///      end fails before it has written any of the codehashes.
    function declare() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        string memory releaseTag = vm.envString("DOTNS_RELEASE_TAG");

        initDeployment(networkFolder(), vm.toString(block.chainid));

        Addresses memory addr = _loadAddresses();

        _declareCodeIdentity(owner, addr);
        _verifyDeployment(addr, owner);
        _declareProtocolVersion(owner, addr, releaseTag);

        console.log("=== DeclareRelease complete ===");
    }
}
