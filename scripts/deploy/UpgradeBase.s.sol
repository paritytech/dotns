// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Script.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {BaseDeployer} from "./BaseDeployer.s.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";

/// @notice Minimal view of a UUPS proxy: the upgrade entrypoint its owner calls.
interface IUUPS {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

/// @title UpgradeBase
/// @notice Shared machinery for the in-place upgrade pipeline.
/// @dev The fresh-deploy pipeline cannot upgrade a live chain. Every DotNS address is a CREATE3
///      address, so where DotNS already exists `_deployCreate3` finds the slot occupied and
///      returns the existing contract: a redeploy reports success and changes nothing. These
///      stages instead deploy new implementations and re-point the existing proxies, leaving
///      every address and all state alone.
/// @dev Split into stages for the same reason the deploy is: each runs as its own `forge script`
///      process, so the OpenZeppelin validator's per-call memory never crosses into the next
///      stage. One process validating every contract exhausts `memory_limit` part-way through.
/// @dev Implementations are deployed with plain CREATE, not CREATE3. Only proxies need stable
///      addresses; an implementation is reached through its proxy. Reusing a CREATE3 salt here
///      would hit the same occupied-slot problem and re-point a proxy at the implementation it
///      already ran.
/// @dev What this validates, and what it does not. `Upgrades.validateImplementation` runs on every
///      contract, catching the unsafe-pattern class (constructor state, `selfdestruct`, unguarded
///      `delegatecall`, missing initialiser). It does **not** compare storage layout against what
///      is deployed: that needs the deployed release's build info as a reference, and a dotns
///      release publishes ABIs rather than build info. Set `DOTNS_UPGRADE_REFERENCE_DIR` to a
///      build-info directory from that release to turn the layout check on.
/// @custom:security-contact admin@parity.io
abstract contract UpgradeBase is BaseDeployer {
    /// @dev EIP-1967 implementation slot: `keccak256("eip1967.proxy.implementation") - 1`.
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 internal _upgradedCount;
    uint256 internal _unchangedCount;

    /// @notice Resolves the protocol registry and announces the stage.
    /// @param stage Stage name, for the log header.
    /// @return owner Broadcasting account, which must own every proxy this stage touches.
    /// @return protocolRegistry The address every other one is resolved from.
    function _beginUpgrade(string memory stage)
        internal
        returns (address owner, address protocolRegistry)
    {
        owner = msg.sender;
        vm.label(owner, "OWNER");

        protocolRegistry = vm.envAddress("DOTNS_PROTOCOL_REGISTRY");
        _requireContract("DotnsProtocolRegistry", protocolRegistry);

        console.log("=== %s ===", stage);
        console.log("  protocol registry:", protocolRegistry);
        console.log("  upgrading as:     ", owner);
        console.log("");
    }

    /// @notice Prints what the stage did.
    function _endUpgrade(string memory stage) internal view {
        console.log("");
        console.log("=== %s complete ===", stage);
        console.log("  upgraded: ", _upgradedCount);
        console.log("  unchanged:", _unchangedCount);
    }

    /// @notice Points one registry-resolved proxy at a freshly deployed implementation.
    /// @dev A key the registry does not hold is skipped rather than treated as an error, so a
    ///      stage also runs against a deployment predating that contract's introduction.
    /// @param owner Broadcasting account.
    /// @param protocolRegistry Address book to resolve `key` through.
    /// @param key Registry key, or `bytes32(0)` for the registry itself.
    /// @param artefact Fully-qualified artefact name of the new implementation.
    /// @param label Bare contract name, used for logging and as the reference name.
    function _upgradeProxy(
        address owner,
        address protocolRegistry,
        bytes32 key,
        string memory artefact,
        string memory label
    )
        internal
    {
        // The registry cannot look itself up, so its key is the zero sentinel.
        address proxy = key == bytes32(0)
            ? protocolRegistry
            : IDotnsProtocolRegistry(protocolRegistry).get(key);

        if (proxy == address(0)) {
            console.log("  skip      %s (not registered on this deployment)", label);
            return;
        }

        _validate(artefact, label);

        vm.startBroadcast(owner);
        address implementation = _deployImplementation(artefact);
        address current = _implementationOf(proxy);

        // Byte-identical code means this contract did not change in the release being applied.
        // Skipping keeps a re-run cheap and makes the summary say what actually moved.
        if (current.codehash == implementation.codehash) {
            vm.stopBroadcast();
            console.log("  unchanged %s", label);
            ++_unchangedCount;
            return;
        }

        IUUPS(proxy).upgradeToAndCall(implementation, bytes(""));
        vm.stopBroadcast();

        console.log("  upgraded  %s", label);
        console.log("            proxy          ", proxy);
        console.log("            was            ", current);
        console.log("            now            ", implementation);
        ++_upgradedCount;
    }

    /// @notice Runs the OpenZeppelin checks, with layout comparison when a reference is supplied.
    function _validate(string memory artefact, string memory label) private {
        Options memory opts;
        string memory referenceDir = vm.envOr("DOTNS_UPGRADE_REFERENCE_DIR", string(""));
        if (bytes(referenceDir).length == 0) {
            Upgrades.validateImplementation(artefact, opts);
            return;
        }

        opts.referenceBuildInfoDir = referenceDir;
        // With a reference build info directory the reference is named
        // `<directory short name>:<contract>`, not by artefact path. The short name is the
        // directory's own basename, and `label` is already the bare contract name.
        opts.referenceContract = string.concat(_basename(referenceDir), ":", label);
        Upgrades.validateUpgrade(artefact, opts);
    }

    /// @notice Deploys an implementation with plain CREATE.
    /// @dev Deliberately not CREATE3: see the contract-level note.
    function _deployImplementation(string memory artefact)
        internal
        returns (address implementation)
    {
        bytes memory creationCode = vm.getCode(artefact);
        assembly ("memory-safe") {
            implementation := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(
            implementation != address(0), string.concat(artefact, ": implementation deploy failed")
        );
    }

    /// @notice Reads a proxy's current implementation from its EIP-1967 slot.
    function _implementationOf(address proxy) internal view returns (address implementation) {
        implementation = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    /// @notice The last path segment of `path`, with any trailing slash ignored.
    /// @dev OZ names a reference by the build info directory's short name, which is its basename.
    function _basename(string memory path) internal pure returns (string memory name) {
        bytes memory raw = bytes(path);
        uint256 end = raw.length;
        if (end != 0 && raw[end - 1] == "/") --end;

        uint256 start;
        for (uint256 i = end; i > 0; --i) {
            if (raw[i - 1] == "/") {
                start = i;
                break;
            }
        }

        bytes memory out = new bytes(end - start);
        for (uint256 i; i < out.length; ++i) {
            out[i] = raw[start + i];
        }
        return string(out);
    }

    /// @dev Registry keys, re-exported so the stages read as a table.
    function _key(string memory name) internal pure returns (bytes32 key) {
        if (_eq(name, "registrar")) return DotnsConstants.REGISTRAR;
        if (_eq(name, "controller")) return DotnsConstants.CONTROLLER;
        if (_eq(name, "registry")) return DotnsConstants.REGISTRY;
        if (_eq(name, "reverseResolver")) return DotnsConstants.REVERSE_RESOLVER;
        if (_eq(name, "resolver")) return DotnsConstants.RESOLVER;
        if (_eq(name, "contentResolver")) return DotnsConstants.CONTENT_RESOLVER;
        if (_eq(name, "popResolver")) return DotnsConstants.POP_RESOLVER;
        if (_eq(name, "popController")) return DotnsConstants.POP_CONTROLLER;
        if (_eq(name, "popRules")) return DotnsConstants.POP_RULES;
        if (_eq(name, "nameEscrow")) return DotnsConstants.NAME_ESCROW;
        if (_eq(name, "nameWhitelist")) return DotnsConstants.NAME_WHITELIST;
        if (_eq(name, "storeFactory")) return DotnsConstants.STORE_FACTORY;
        revert(string.concat("unknown registry key: ", name));
    }

    function _eq(string memory a, string memory b) private pure returns (bool equal) {
        equal = keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
