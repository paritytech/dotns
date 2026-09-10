// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";

import {BaseDeployer} from "./BaseDeployer.s.sol";
import {DotnsPopLens} from "../../contracts/registrars/DotnsPopLens.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title RedeployPopLens
/// @notice Redeploys the DotnsPopLens read helper and repoints the protocol registry `popLens` key
///         at the new instance. The lens is immutable and holds no state, so it is replaced rather
///         than upgraded: it reads a lite name at its hierarchical node, which the previous
///         implementation did not, and nothing on chain calls it, so the swap only affects
///         off-chain enumeration.
/// @dev PR-scoped. This script and the paired `test/fork/RedeployPopLens.t.sol` are deleted before
///      merge per the upgrade-PR workflow in CONTRIBUTING.md. There is no proxy and so no storage
///      layout to diff: the lens binds the protocol registry in its constructor and derives every
///      answer from a live registry read.
/// @custom:security-contact admin@parity.io
contract RedeployPopLens is BaseDeployer {
    /// @notice Manifest label the protocol registry proxy is recorded under.
    string internal constant PROTOCOL_REGISTRY_LABEL = "DotnsProtocolRegistry";

    /// @notice Reads the manifest, resolves the protocol registry, and redeploys the lens as
    ///         `msg.sender`.
    /// @dev `msg.sender` must own the protocol registry, otherwise the `set` owner gate reverts.
    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        initDeployment(networkFolder(), vm.toString(block.chainid));

        address registry = _readAddress(PROTOCOL_REGISTRY_LABEL);
        _redeployPopLens(owner, registry);

        console.log("=== RedeployPopLens complete ===");
    }

    /// @notice Deploys a fresh lens bound to `registry` and repoints the `popLens` key at it.
    /// @dev A plain deploy is used rather than the deterministic factory so the replacement lands
    /// at a fresh address instead of colliding with the live lens at its salted address. The
    ///      registry `set` is owner gated, so the broadcaster must own the protocol registry.
    /// @param owner Account that owns the protocol registry and broadcasts the redeploy.
    /// @param registry Protocol registry proxy address resolved from the manifest.
    function _redeployPopLens(address owner, address registry) internal {
        require(
            owner == OwnableUpgradeable(registry).owner(),
            "RedeployPopLens: broadcaster is not the protocol registry owner"
        );

        vm.startBroadcast(owner);
        DotnsPopLens lens = new DotnsPopLens(IDotnsProtocolRegistry(registry));
        IDotnsProtocolRegistry(registry).set(DotnsConstants.POP_LENS, address(lens));
        vm.stopBroadcast();

        console.log("  redeployed DotnsPopLens", address(lens));
    }
}
