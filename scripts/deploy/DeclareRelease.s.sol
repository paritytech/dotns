// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";

import {WireDeployments} from "./WireDeployments.s.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";

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

        _wireMissingKeys(owner, addr);
        _declareCodeIdentity(owner, addr);
        _verifyDeployment(addr, owner);
        _declareProtocolVersion(owner, addr, releaseTag);

        console.log("=== DeclareRelease complete ===");
    }

    /// @notice Sets any registry key that is still unset, and leaves the rest alone.
    /// @dev A network wired before a key existed carries a hole that a fresh deploy never has,
    ///      and `_verifyDeployment` fails on it at the last step of an upgrade, after every swap
    ///      has already been broadcast. Paseo Asset Hub Next has exactly one: `protocolRegistry`,
    ///      the registry's self-reference, which resolves to the zero address there. The key
    ///      exists so the registry's own implementation has a declared codehash to drift from;
    ///      consumers bootstrap from the manifest address, so nothing is broken by its absence
    ///      until something tries to declare against it.
    ///
    ///      Only unset keys are written. A key pointing somewhere unexpected is left exactly as
    ///      it is, so `_verifyDeployment` still fails on it: that is drift, and repairing it here
    ///      would make the verification that follows tautological and hide the thing it exists to
    ///      surface.
    /// @param owner Account that owns the registry and broadcasts.
    /// @param addr Deployment addresses read from the manifest.
    function _wireMissingKeys(address owner, Addresses memory addr) internal {
        IDotnsProtocolRegistry registry = IDotnsProtocolRegistry(addr.protocolRegistry);
        RegistryEntry[] memory entries = _registryEntries(addr);

        for (uint256 i; i < entries.length; ++i) {
            if (registry.get(entries[i].key) != address(0)) continue;

            vm.broadcast(owner);
            registry.set(entries[i].key, entries[i].target);
            console.log("  wired missing key", entries[i].label, entries[i].target);
        }
    }
}
