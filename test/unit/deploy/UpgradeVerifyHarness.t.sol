// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {UpgradeVerify} from "../../../scripts/deploy/UpgradeVerify.s.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";

/// @notice Test-only harness exposing each `UpgradeVerify` check so a single failure can be
///         asserted on its own rather than inferred from a whole-graph run.
contract UpgradeVerifyHarness is UpgradeVerify {
    function present(
        IDotnsProtocolRegistry registry,
        bytes32 key,
        string memory name,
        address expectedOwner,
        bool ownerless
    )
        external
        view
    {
        _present(registry, key, name, expectedOwner, ownerless);
    }

    function verifyRegistrySelf(address registryAddress, address expectedOwner) external view {
        _verifyRegistrySelf(registryAddress, expectedOwner);
    }

    function verifyControllers(IDotnsProtocolRegistry registry) external view {
        _verifyControllers(registry);
    }

    function verifyStoreBeacons(IDotnsProtocolRegistry registry) external view {
        _verifyStoreBeacons(registry);
    }

    function verifyConfiguration(IDotnsProtocolRegistry registry) external view {
        _verifyConfiguration(registry);
    }
}
