// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";

import {BaseDeployer} from "./BaseDeployer.s.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";

/// @title RedeployPopLens
/// @notice Deploys the current DotnsPopLens, points the `popLens` key at it, declares its
///         codehash, and records it in the manifest.
/// @dev The lens is a plain contract with an immutable protocol registry and no storage, so a new
///      release replaces it with a fresh deployment. It reads the PoP resolver through the
///      current getters, so it runs after `UpgradePopResolverAndController`.
///
///      The deterministic CREATE3 address a fresh deploy uses for the lens is already occupied on
///      networks that ran an earlier lens there, and CREATE3 slots are single use. This script
///      takes its own salt, scoped to the release in `DOTNS_RELEASE_TAG`, so the address is known
///      before broadcasting and a re-run adopts the lens a previous run deployed.
///
///      The key and the codehash are written in consecutive transactions. `DEPLOYMENT_CHECKLIST.md`
///      treats a rewire without a matching declaration as drift, indistinguishable from an
///      unauthorised swap.
///
///      The outgoing lens is dropped from the manifest. Nothing holds state in it or points at it
///      once the key moves, so it needs no `*Legacy` entry.
/// @custom:security-contact admin@parity.io
contract RedeployPopLens is BaseDeployer {
    /// @notice Manifest label the lens is recorded under.
    string internal constant POP_LENS_LABEL = "DotnsPopLens";

    /// @notice Manifest label of the protocol registry.
    string internal constant PROTOCOL_REGISTRY_LABEL = "DotnsProtocolRegistry";

    /// @notice Lens artefact deployed by this script.
    string internal constant POP_LENS_ARTEFACT = "DotnsPopLens.sol:DotnsPopLens";

    /// @notice Deploys and wires the lens as `msg.sender`, then saves the manifest.
    /// @dev `msg.sender` must own the protocol registry. The manifest's current lens is asserted
    ///      against the `popLens` key before anything is broadcast, so a manifest that disagrees
    ///      with the chain stops the run.
    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        initDeployment(networkFolder(), vm.toString(block.chainid));

        address protocolRegistry = _readAddress(PROTOCOL_REGISTRY_LABEL);
        address outgoing = _readAddress(POP_LENS_LABEL);
        string memory releaseTag = vm.envString("DOTNS_RELEASE_TAG");

        _redeployPopLens(owner, protocolRegistry, outgoing, releaseTag);
        saveDeployments();

        console.log("=== RedeployPopLens complete ===");
    }

    /// @notice Deploys the lens at its release-scoped CREATE3 address, records it in the in-memory
    ///         manifest, and wires the key to it.
    /// @dev A re-run after the deploy adopts the lens at the predicted address, and the key writes
    ///      are skipped once the chain already holds them, so the script can be run again after a
    ///      failure at any point.
    /// @param owner Account that owns the protocol registry and broadcasts.
    /// @param protocolRegistry Registry the lens binds to and the key lives on.
    /// @param outgoing Lens the manifest records today.
    /// @param releaseTag Bare semver of the release being deployed, for example `1.0.0`.
    /// @return lens Address of the new lens.
    function _redeployPopLens(
        address owner,
        address protocolRegistry,
        address outgoing,
        string memory releaseTag
    )
        internal
        returns (address lens)
    {
        IDotnsProtocolRegistry registry = IDotnsProtocolRegistry(protocolRegistry);
        require(
            owner == OwnableUpgradeable(protocolRegistry).owner(),
            "RedeployPopLens: broadcaster is not the protocol registry owner"
        );

        address current = registry.get(DotnsConstants.POP_LENS);
        bytes32 salt = _create3Salt(POP_LENS_LABEL, string.concat("contract:", releaseTag));
        _setCreate3Factory(registry.get(DotnsConstants.CREATE3_FACTORY));
        address predicted = _create3Factory().predict(salt);
        require(
            current == outgoing || current == predicted,
            "RedeployPopLens: popLens key matches neither the manifest nor this release's lens"
        );

        lens = _broadcastDeployCreate3(
            owner, POP_LENS_ARTEFACT, abi.encode(protocolRegistry), POP_LENS_LABEL, salt
        );
        console.log("  lens at", lens);

        if (registry.get(DotnsConstants.POP_LENS) != lens) {
            vm.broadcast(owner);
            registry.set(DotnsConstants.POP_LENS, lens);
        }
        if (registry.expectedCodehash(DotnsConstants.POP_LENS) != lens.codehash) {
            vm.broadcast(owner);
            registry.setExpectedCodehash(DotnsConstants.POP_LENS, lens.codehash);
        }

        require(
            registry.get(DotnsConstants.POP_LENS) == lens,
            "RedeployPopLens: popLens key did not take"
        );
        require(
            registry.expectedCodehash(DotnsConstants.POP_LENS) == lens.codehash,
            "RedeployPopLens: popLens codehash declaration did not take"
        );
    }
}
