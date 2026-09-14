// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {RedeployPopLens} from "../../scripts/deploy/RedeployPopLens.s.sol";

/// @title RedeployPopLensHarness
/// @notice Exposes the redeploy script's internal path so the fork test drives the exact code the
///         production run executes.
/// @dev Mirrors the `DeterministicDeploymentHarness` pattern: forward to the script internal rather
///      than re-implement the redeploy, so the test tracks the production path one-to-one.
contract RedeployPopLensHarness is RedeployPopLens {
    /// @notice Redeploys the lens under `owner` through the script's `_redeployPopLens`.
    function redeployPopLens(address owner, address registry) external {
        _redeployPopLens(owner, registry);
    }
}

/// @title RedeployPopLensForkTest
/// @notice Pairs one-to-one with `scripts/deploy/RedeployPopLens.s.sol`. Forks the live Paseo Asset
///         Hub through the ETH-RPC adapter, redeploys the lens against the live protocol registry,
///         and reads the `popLens` key back to prove it points at the fresh instance.
/// @dev PR-scoped: deleted before merge with the redeploy script per the upgrade-PR workflow in
///      CONTRIBUTING.md. Requires the local adapter on `paseo_local`; between upgrade PRs
///      `test/fork/` is empty, so the suite is skipped by default with `--no-match-path
///      'test/fork/**'`.
/// @custom:security-contact admin@parity.io
contract RedeployPopLensForkTest is Test {
    /// @notice Manifest recording the live deployment addresses this fork resolves against.
    string internal constant MANIFEST_PATH = "deployments/paseo-assethub/420420417.json";

    /// @notice Drives the redeploy path against the live protocol registry.
    RedeployPopLensHarness internal redeployer;

    /// @notice The deployed protocol registry that records the `popLens` key.
    IDotnsProtocolRegistry internal protocolRegistry;

    /// @notice Protocol registry owner, impersonated to authorise the key repoint.
    address internal registryOwner;

    /// @notice Forks Paseo, resolves the live protocol registry, and reads the owner.
    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("paseo_local"));

        string memory manifest = vm.readFile(MANIFEST_PATH);
        protocolRegistry =
            IDotnsProtocolRegistry(vm.parseJsonAddress(manifest, ".DotnsProtocolRegistry"));
        registryOwner = OwnableUpgradeable(address(protocolRegistry)).owner();

        redeployer = new RedeployPopLensHarness();
    }

    /// @notice The redeploy repoints the `popLens` key at a fresh, non-zero lens address.
    function test_redeploy_repoints_pop_lens_key() public {
        address lensBefore = protocolRegistry.get(DotnsConstants.POP_LENS);

        redeployer.redeployPopLens(registryOwner, address(protocolRegistry));

        address lensAfter = protocolRegistry.get(DotnsConstants.POP_LENS);
        assertTrue(lensAfter != address(0), "popLens key is set to the fresh lens");
        assertTrue(lensAfter != lensBefore, "popLens key repointed away from the previous lens");
    }
}
