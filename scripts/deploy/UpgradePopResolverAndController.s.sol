// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {BaseDeployer} from "./BaseDeployer.s.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IDotnsPopController} from "../../contracts/registrars/IDotnsPopController.sol";
import {IDotnsPopResolver} from "../../contracts/resolvers/IDotnsPopResolver.sol";

/// @title UpgradePopResolverAndController
/// @notice Upgrades the deployed DotnsPopResolver and DotnsPopController proxies to the current
///         implementations, resolver first, in consecutive transactions. Resolves both proxies
///         from the on-disk manifest, diffs each new storage layout against its pinned snapshot
///         (@custom:contract DotnsPopResolverOld, @custom:contract DotnsPopControllerOld), and
///         broadcasts only once both diffs and every unsafe-pattern check pass.
/// @dev One script because the two implementations only work in pairs. The new controller writes
///      the personhood link through `setDeviceLink`, which only the new resolver has, and the old
///      controller writes it through `setLiteLink`, which the new resolver drops. Upgrading either
///      alone leaves every linked personhood issuance reverting until the other lands. Between the
///      two transactions here that window is a few blocks, and an issuance that reverts in it
///      writes nothing.
///
///      Both layouts are validated before the first broadcast, so a controller that fails its
///      diff cannot leave the resolver upgraded on its own. Each proxy is upgraded only while it
///      still runs the previous implementation, detected by interface: a run that died between
///      the two transactions is finished by running this script again.
///
///      The resolver's layout changes only by two renames in place, `_liteLinks` to `_deviceLinks`
///      in slot 2 and `_fullClaims` to `_personhoodNodes` in slot 3, with types unchanged. The
///      resolver source declares both through OpenZeppelin's renamed-from annotation, so both
///      diffs run with no override.
///
///      The snapshots are the implementations deployed on chain.
///      `scripts/shell/verify-snapshots.sh` is what holds that property, by building each snapshot
///      and comparing it against the chain. The layout diff cannot: it compares whatever pair it
///      is given, and is blind to a change that lives in calldata.
/// @custom:security-contact admin@parity.io
contract UpgradePopResolverAndController is BaseDeployer {
    /// @notice Pre-upgrade resolver snapshot the resolver layout diff compares against.
    string internal constant RESOLVER_REFERENCE = "DotnsPopResolverOld.sol:DotnsPopResolverOld";

    /// @notice Pre-upgrade controller snapshot the controller layout diff compares against.
    string internal constant CONTROLLER_REFERENCE =
        "DotnsPopControllerOld.sol:DotnsPopControllerOld";

    /// @notice New resolver implementation artefact.
    string internal constant RESOLVER_ARTEFACT = "DotnsPopResolver.sol:DotnsPopResolver";

    /// @notice New controller implementation artefact.
    string internal constant CONTROLLER_ARTEFACT = "DotnsPopController.sol:DotnsPopController";

    /// @notice Manifest label the DotnsPopResolver proxy is recorded under.
    string internal constant POP_RESOLVER_LABEL = "DotnsPopResolver";

    /// @notice Manifest label the DotnsPopController proxy is recorded under.
    string internal constant POP_CONTROLLER_LABEL = "DotnsPopController";

    /// @notice Reads the manifest, resolves both proxies, and upgrades them as `msg.sender`.
    /// @dev `msg.sender` must own both proxies, otherwise the run stops before broadcasting.
    function run() external {
        address owner = msg.sender;
        vm.label(owner, "OWNER");

        initDeployment(networkFolder(), vm.toString(block.chainid));

        address resolver = _readAddress(POP_RESOLVER_LABEL);
        address controller = _readAddress(POP_CONTROLLER_LABEL);
        _upgradeResolverAndController(owner, resolver, controller);

        console.log("=== UpgradePopResolverAndController complete ===");
    }

    /// @notice Upgrades `resolver`, then `controller`, under `owner`.
    /// @dev Empty upgrade calls: neither implementation seeds storage of its own, and the release
    ///      declarations are written once by `DeclareRelease.s.sol` after every swap has verified.
    /// @param owner Account that owns both proxies and broadcasts the upgrades.
    /// @param resolver DotnsPopResolver proxy address resolved from the manifest.
    /// @param controller DotnsPopController proxy address resolved from the manifest.
    function _upgradeResolverAndController(
        address owner,
        address resolver,
        address controller
    )
        internal
    {
        require(
            owner == OwnableUpgradeable(resolver).owner(),
            "UpgradePopResolverAndController: broadcaster is not the resolver owner"
        );
        require(
            owner == OwnableUpgradeable(controller).owner(),
            "UpgradePopResolverAndController: broadcaster is not the controller owner"
        );

        Options memory resolverOpts = _resolverOptions();
        Options memory controllerOpts = _controllerOptions();
        Upgrades.validateUpgrade(RESOLVER_ARTEFACT, resolverOpts);
        Upgrades.validateUpgrade(CONTROLLER_ARTEFACT, controllerOpts);

        if (_resolverUpgraded(resolver)) {
            console.log("  DotnsPopResolver proxy already upgraded, skipping", resolver);
        } else {
            vm.startBroadcast(owner);
            Upgrades.upgradeProxy(resolver, RESOLVER_ARTEFACT, "", resolverOpts);
            vm.stopBroadcast();
            console.log("  upgraded DotnsPopResolver proxy", resolver);
        }

        if (_controllerUpgraded(controller)) {
            console.log("  DotnsPopController proxy already upgraded, skipping", controller);
        } else {
            vm.startBroadcast(owner);
            Upgrades.upgradeProxy(controller, CONTROLLER_ARTEFACT, "", controllerOpts);
            vm.stopBroadcast();
            console.log("  upgraded DotnsPopController proxy", controller);
        }

        require(
            _resolverUpgraded(resolver) && _controllerUpgraded(controller),
            "UpgradePopResolverAndController: a proxy still runs the previous implementation"
        );
    }

    /// @notice Layout-diff options for the resolver: its snapshot and nothing else.
    function _resolverOptions() internal pure returns (Options memory opts) {
        opts.referenceContract = RESOLVER_REFERENCE;
    }

    /// @notice Layout-diff options for the controller: its snapshot and nothing else.
    function _controllerOptions() internal pure returns (Options memory opts) {
        opts.referenceContract = CONTROLLER_REFERENCE;
    }

    /// @notice Whether `resolver` already runs an implementation exposing `deviceLabelhashOf`.
    /// @dev The previous implementation has no such function, so the static call reverts there.
    /// @param resolver DotnsPopResolver proxy.
    /// @return upgraded True once the new implementation is behind the proxy.
    function _resolverUpgraded(address resolver) internal view returns (bool upgraded) {
        (upgraded,) =
            resolver.staticcall(abi.encodeCall(IDotnsPopResolver.deviceLabelhashOf, (bytes32(0))));
    }

    /// @notice Whether `controller` already runs an implementation reporting the current interface.
    /// @dev The previous implementation reports its own interface id, which differs from this one
    ///      because the issuance entrypoints changed.
    /// @param controller DotnsPopController proxy.
    /// @return upgraded True once the new implementation is behind the proxy.
    function _controllerUpgraded(address controller) internal view returns (bool upgraded) {
        upgraded = IERC165(controller).supportsInterface(type(IDotnsPopController).interfaceId);
    }
}
