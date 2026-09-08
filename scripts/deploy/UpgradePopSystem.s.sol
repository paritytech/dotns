// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {UpgradeBase} from "./UpgradeBase.s.sol";

/// @title UpgradePopSystem
/// @notice Final upgrade stage, mirroring `DeployPopSystem`: the personhood gateway surface.
/// @dev `DotnsPopLens` is absent because it is not upgradeable. It holds no state and is read
///      only, so a change to it is delivered by deploying a new lens and re-pointing the
///      `popLens` registry key.
/// @custom:security-contact admin@parity.io
contract UpgradePopSystem is UpgradeBase {
    function run() external {
        (address owner, address registry) = _beginUpgrade("UpgradePopSystem");

        _upgradeProxy(
            owner,
            registry,
            _key("popController"),
            "DotnsPopController.sol:DotnsPopController",
            "DotnsPopController"
        );
        _upgradeProxy(
            owner,
            registry,
            _key("popResolver"),
            "DotnsPopResolver.sol:DotnsPopResolver",
            "DotnsPopResolver"
        );

        _endUpgrade("UpgradePopSystem");
    }
}
