// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @title LayoutCompatibilityTests
/// @notice Runs the OpenZeppelin storage-layout diff for every proxy this branch upgrades,
///         against the snapshot of the implementation deployed on chain.
/// @dev This is the cheap half of the upgrade check and it needs no fork, so it runs in ordinary
///      CI on every push rather than only when someone brings up the ETH-RPC adapter. It answers
///      one question per proxy: would `Upgrades.upgradeProxy` accept this layout change. It cannot
///      answer whether the snapshot is the deployed code, which has no on-chain counterpart in a
///      layout at all; `scripts/shell/verify-snapshots.sh` answers that by comparing bytecode, and
///      the two together are what make an upgrade script trustworthy.
/// @custom:security-contact admin@parity.io
contract LayoutCompatibilityTests is Test {
    /// @notice Asserts the new implementation is layout-compatible with the deployed one.
    /// @dev `validateUpgrade` runs the same diff `upgradeProxy` runs, and reverts with the
    ///      offending slot when it fails, so a regression names the field rather than the pair.
    /// @param newContract Artefact of the implementation being upgraded to.
    /// @param referenceContract Artefact of the snapshot of what is deployed.
    function _assertCompatible(
        string memory newContract,
        string memory referenceContract
    )
        internal
    {
        Options memory opts;
        opts.referenceContract = referenceContract;
        Upgrades.validateUpgrade(newContract, opts);
    }

    function test_registry_layout_is_compatible() public {
        _assertCompatible(
            "DotnsRegistry.sol:DotnsRegistry", "DotnsRegistryOld.sol:DotnsRegistryOld"
        );
    }

    function test_protocolRegistry_layout_is_compatible() public {
        // The one proxy that genuinely adds storage: #304 appends `_protocolVersion` and
        // `_expectedCodehash` and shrinks the gap to match, which is an append, not a move.
        _assertCompatible(
            "DotnsProtocolRegistry.sol:DotnsProtocolRegistry",
            "DotnsProtocolRegistryOld.sol:DotnsProtocolRegistryOld"
        );
    }

    function test_registrar_layout_is_compatible() public {
        _assertCompatible(
            "DotnsRegistrar.sol:DotnsRegistrar", "DotnsRegistrarOld.sol:DotnsRegistrarOld"
        );
    }

    function test_registrarController_layout_is_compatible() public {
        // The retained `__whiteListSlot` placeholder is what keeps `protocolRegistry` on the slot
        // the live proxy uses. Without it this assertion is what fails.
        _assertCompatible(
            "DotnsRegistrarController.sol:DotnsRegistrarController",
            "DotnsRegistrarControllerOld.sol:DotnsRegistrarControllerOld"
        );
    }

    function test_popController_layout_is_compatible() public {
        _assertCompatible(
            "DotnsPopController.sol:DotnsPopController",
            "DotnsPopControllerOld.sol:DotnsPopControllerOld"
        );
    }

    function test_popRules_layout_is_compatible() public {
        _assertCompatible("PopRules.sol:PopRules", "PopRulesOld.sol:PopRulesOld");
    }

    function test_nameEscrow_layout_is_compatible() public {
        _assertCompatible(
            "DotnsNameEscrow.sol:DotnsNameEscrow", "DotnsNameEscrowOld.sol:DotnsNameEscrowOld"
        );
    }

    function test_nameWhitelist_layout_is_compatible() public {
        _assertCompatible(
            "DotnsNameWhitelist.sol:DotnsNameWhitelist",
            "DotnsNameWhitelistOld.sol:DotnsNameWhitelistOld"
        );
    }

    function test_resolver_layout_is_compatible() public {
        _assertCompatible(
            "DotnsResolver.sol:DotnsResolver", "DotnsResolverOld.sol:DotnsResolverOld"
        );
    }

    function test_reverseResolver_layout_is_compatible() public {
        _assertCompatible(
            "DotnsReverseResolver.sol:DotnsReverseResolver",
            "DotnsReverseResolverOld.sol:DotnsReverseResolverOld"
        );
    }

    function test_contentResolver_layout_is_compatible() public {
        _assertCompatible(
            "DotnsContentResolver.sol:DotnsContentResolver",
            "DotnsContentResolverOld.sol:DotnsContentResolverOld"
        );
    }

    function test_popResolver_layout_is_compatible() public {
        _assertCompatible(
            "DotnsPopResolver.sol:DotnsPopResolver", "DotnsPopResolverOld.sol:DotnsPopResolverOld"
        );
    }
}
