// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";

import {BaseDeployer} from "./BaseDeployer.s.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title RollbackProxy
/// @notice Points one proxy the v1.1.0 campaign upgrades back at the implementation it ran before
///         the campaign, on Paseo Asset Hub Next.
/// @dev `ROLLBACK_PROXY` names the proxy by its manifest label: `PopRules`, `DotnsPopController`
///      or `DotnsRegistrarController`. The previous implementations are still deployed, and their
///      storage layouts are the snapshots the campaign was validated against, so the rollback is a
///      single `upgradeToAndCall` with empty call data and deploys nothing.
///
///      PopRules cannot go back while the controller runs the new implementation, which calls
///      `PopRules.reassignBaseNameForPop`, so the script refuses until the controller is rolled
///      back first. A proxy that already runs its previous implementation broadcasts nothing.
/// @custom:security-contact admin@parity.io
contract RollbackProxy is BaseDeployer {
    /// @notice Chain id of Paseo Asset Hub Next, the only network these addresses describe.
    uint256 internal constant PASEO_CHAIN_ID = 420420417;

    /// @notice PopRules implementation before the campaign.
    address internal constant POP_RULES_PREVIOUS = 0xdf1800BA0055C2cA3587400831123e9bCD4d5818;

    /// @notice DotnsPopController implementation before the campaign.
    address internal constant POP_CONTROLLER_PREVIOUS = 0xF8901566396dB4333cE511693992124D28507795;

    /// @notice DotnsRegistrarController implementation before the campaign.
    address internal constant REGISTRAR_CONTROLLER_PREVIOUS =
        0x310Dd512Fc43e267798e02E81FC0d9628307Cfb2;

    /// @notice ERC-1967 implementation slot.
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @notice Reads the manifest, resolves the named proxy, and rolls it back as `msg.sender`.
    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");
        require(block.chainid == PASEO_CHAIN_ID, "RollbackProxy: Paseo Asset Hub Next only");

        initDeployment(networkFolder(), vm.toString(block.chainid));

        string memory label = vm.envString("ROLLBACK_PROXY");
        _rollback(owner, label, _readAddress(label), _readAddress("DotnsPopController"));

        console.log("=== RollbackProxy complete ===");
    }

    /// @notice Points `proxy` back at its previous implementation under `owner`.
    /// @param owner Account that owns the proxy and broadcasts the upgrade.
    /// @param label Manifest label of the proxy.
    /// @param proxy Proxy address resolved from the manifest.
    /// @param controller DotnsPopController proxy, read to order a PopRules rollback.
    function _rollback(
        address owner,
        string memory label,
        address proxy,
        address controller
    )
        internal
    {
        address previous = _previousImplementation(label);
        require(previous.code.length != 0, "RollbackProxy: previous implementation has no code");
        require(
            owner == OwnableUpgradeable(proxy).owner(),
            "RollbackProxy: broadcaster is not the owner"
        );
        if (previous == POP_RULES_PREVIOUS) {
            (bool controllerUpgraded,) =
                controller.staticcall(abi.encodeWithSignature("MAX_QUEUE_STEPS_PER_CALL()"));
            require(!controllerUpgraded, "RollbackProxy: roll back DotnsPopController first");
        }

        if (_implementationOf(proxy) == previous) {
            console.log("  already on the previous implementation, skipping", label);
            return;
        }

        vm.broadcast(owner);
        UUPSUpgradeable(proxy).upgradeToAndCall(previous, "");

        require(_implementationOf(proxy) == previous, "RollbackProxy: implementation did not move");
        console.log("  rolled back", label, previous);
    }

    /// @notice The implementation `label` ran before the campaign.
    /// @param label Manifest label of the proxy.
    /// @return previous Previous implementation address.
    function _previousImplementation(string memory label) internal pure returns (address previous) {
        bytes32 key = keccak256(bytes(label));
        if (key == keccak256("PopRules")) return POP_RULES_PREVIOUS;
        if (key == keccak256("DotnsPopController")) return POP_CONTROLLER_PREVIOUS;
        if (key == keccak256("DotnsRegistrarController")) return REGISTRAR_CONTROLLER_PREVIOUS;
        revert("RollbackProxy: ROLLBACK_PROXY is not a proxy this campaign upgrades");
    }

    /// @notice Reads the implementation behind an ERC-1967 proxy.
    /// @param proxy Proxy to read.
    /// @return implementation Current implementation address.
    function _implementationOf(address proxy) internal view returns (address implementation) {
        implementation = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }
}
