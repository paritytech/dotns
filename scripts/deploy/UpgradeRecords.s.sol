// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {UpgradeBase} from "./UpgradeBase.s.sol";

/// @title UpgradeRecords
/// @notice Second upgrade stage, mirroring `DeployRecords`: the resolvers and the pricing rules.
/// @dev The cost-model stack (`DotnsCostModelRegistry`, `DotnsFlatPricing`, `DotnsScarcityPricing`)
///      is deliberately absent. None of them is upgradeable; a pricing change is delivered by
///      deploying a new model and re-pointing the cost-model registry, not by an implementation
///      swap.
/// @custom:security-contact admin@parity.io
contract UpgradeRecords is UpgradeBase {
    function run() external {
        (address owner, address registry) = _beginUpgrade("UpgradeRecords");

        _upgradeProxy(
            owner, registry, _key("resolver"), "DotnsResolver.sol:DotnsResolver", "DotnsResolver"
        );
        _upgradeProxy(
            owner,
            registry,
            _key("contentResolver"),
            "DotnsContentResolver.sol:DotnsContentResolver",
            "DotnsContentResolver"
        );
        _upgradeProxy(owner, registry, _key("popRules"), "PopRules.sol:PopRules", "PopRules");

        _endUpgrade("UpgradeRecords");
    }
}
