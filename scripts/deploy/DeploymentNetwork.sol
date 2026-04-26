// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title DeploymentNetwork
/// @notice Maps the current chain ID to the subdirectory under
///         `deployments/` every stage script reads from and writes to.
/// @dev Shared by every stage so the manifest path stays consistent across
///      the pipeline. Adding a new network is a single-line change here.
/// @custom:security-contact admin@parity.io
library DeploymentNetwork {
    function folder(uint256 chainId) internal pure returns (string memory name) {
        if (chainId == 420420422) return "passethub-testnet";
        if (chainId == 420420417) return "paseo-assethub";
        if (chainId == 420420420) return "paseo-local";
        return "localhost";
    }
}
