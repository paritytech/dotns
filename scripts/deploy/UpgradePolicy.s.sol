// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {UpgradeBase} from "./UpgradeBase.s.sol";

/// @title UpgradePolicy
/// @notice Third upgrade stage, mirroring `DeployPolicy`: registration, escrow and the name grants
///         that admit a reserved registration.
/// @custom:security-contact admin@parity.io
contract UpgradePolicy is UpgradeBase {
    function run() external {
        (address owner, address registry) = _beginUpgrade("UpgradePolicy");

        _upgradeProxy(
            owner,
            registry,
            _key("nameEscrow"),
            "DotnsNameEscrow.sol:DotnsNameEscrow",
            "DotnsNameEscrow"
        );
        _upgradeProxy(
            owner,
            registry,
            _key("nameWhitelist"),
            "DotnsNameWhitelist.sol:DotnsNameWhitelist",
            "DotnsNameWhitelist"
        );
        _upgradeProxy(
            owner,
            registry,
            _key("controller"),
            "DotnsRegistrarController.sol:DotnsRegistrarController",
            "DotnsRegistrarController"
        );

        _endUpgrade("UpgradePolicy");
    }
}
