// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title DeploymentNetwork
/// @notice Maps a chain ID to the default subdirectory under `deployments/`
///         that the deploy pipeline reads from and writes to.
/// @dev Single source of the chain-id defaults, shared by every stage so the
///      manifest path stays consistent across the pipeline. Adding a new
///      network is a single-line change here. When two chains present the same
///      chain ID, `BaseDeployer.networkFolder` lets a `DEPLOYMENT_NETWORK`
///      environment variable override this default so their manifests do not
///      collide.
/// @custom:security-contact admin@parity.io
library DeploymentNetwork {
    /// @notice Returns the default manifest subdirectory for `chainId`.
    /// @param chainId Chain ID reported by the target network.
    /// @return name Folder under `deployments/`, or `localhost` when unmapped.
    function folder(uint256 chainId) internal pure returns (string memory name) {
        if (chainId == 420420422) return "passethub-testnet";
        if (chainId == 420420417) return "paseo-assethub";
        if (chainId == 420420420) return "paseo-local";
        return "localhost";
    }
}
