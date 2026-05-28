// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script} from "forge-std/Script.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Create2Factory} from "../../contracts/utils/Create2Factory.sol";

/// @title BaseDeployer
/// @notice Shared base for the DotNS deploy pipeline. Each concrete stage
///         script reads the manifest from disk (populated by prior stages),
///         deploys its own proxies through the singleton CREATE2 factory in
///         its own forge-script process, and writes the updated manifest
///         back.
/// @dev The pipeline is split across separate `forge script` invocations so
///      each OpenZeppelin upgrade-safety validation runs in a fresh EVM
///      simulation. EVM memory gas is quadratic, and a monolithic script
///      accumulates it across every validator FFI call until the block gas
///      limit is hit. Separate processes side-step the accumulation entirely
///      without skipping any OZ check.
///
///      Every contract — UUPS implementations, ERC1967 proxies, and plain
///      `new`-style contracts alike — is deployed through the singleton
///      `Create2Factory` whose address is supplied via the `CREATE2_FACTORY`
///      env var that `run.sh` exports before invoking each stage. With the
///      factory at the same address on every chain (enforced by the wrapper
///      script's deployer-nonce check), role-versioned salts give every
///      protocol contract the same address on every chain.
/// @custom:security-contact admin@parity.io
abstract contract BaseDeployer is Script {
    /// @notice JSON object key used internally by the `vm.serializeAddress`
    ///         helper. The value is arbitrary; it only has to be stable across
    ///         successive calls within the same run.
    string internal constant MANIFEST_OBJECT_KEY = "dotns.manifest";

    /// @notice Env var the wrapper exports to advertise the singleton
    ///         CREATE2 factory's address to every stage.
    string internal constant CREATE2_FACTORY_ENV = "CREATE2_FACTORY";

    /// @notice Project-wide salt prefix. Combined with `role` and `version`
    ///         per contract by `_saltFor`. Changing the prefix re-namespaces
    ///         every address simultaneously, which is intentionally a heavy
    ///         operation — leave it alone outside of a coordinated migration.
    string internal constant SALT_PREFIX = "dotns:";

    /// @notice In-memory JSON string representing the full deployment manifest
    ///         accumulated across this stage's calls to `logDeployment`.
    string private manifestJson;

    /// @notice Disk path the current stage reads from and writes to. Populated
    ///         by `initDeployment`.
    string private manifestPath;

    /// @notice Cached factory address, set by `initFactory`. Stages must call
    ///         `initFactory` before any deploy helper so the address is
    ///         resolved exactly once per run.
    address private create2Factory;

    /// @notice Loads the existing deployment manifest for `(subdirectory, filename)`
    ///         if one exists; otherwise begins a fresh in-memory object. Every
    ///         stage must call this first so subsequent `_readAddress` / `logDeployment`
    ///         calls see the correct baseline.
    /// @dev The disk format is `{"ContractName": "0x..."}`. Using foundry's
    ///      native serializer keeps parsing and writing symmetric: the same
    ///      `vm.serializeAddress` value feeds both `vm.writeFile` and
    ///      `vm.parseJsonAddress`.
    /// @param subdirectory Network-specific folder under `deployments/`.
    /// @param filename Stem of the manifest file (for example `block.chainid`).
    function initDeployment(string memory subdirectory, string memory filename) internal {
        manifestPath = _deploymentPath(subdirectory, filename);

        if (vm.exists(manifestPath)) {
            // Prime foundry's internal serializer with every existing entry so
            // subsequent `logDeployment` calls extend the object rather than
            // replace it. `vm.serializeAddress` tracks an object per string
            // key; the FIRST call with a given key starts a fresh object, so
            // we have to re-insert every prior address before the first new
            // log.
            // forge-lint: disable-next-line(unsafe-cheatcode)
            string memory priorJson = vm.readFile(manifestPath);
            string[] memory names = vm.parseJsonKeys(priorJson, "$");

            for (uint256 i = 0; i < names.length; ++i) {
                address addr = vm.parseJsonAddress(priorJson, string.concat(".", names[i]));
                manifestJson = vm.serializeAddress(MANIFEST_OBJECT_KEY, names[i], addr);
            }
            if (names.length == 0) {
                manifestJson = vm.serializeAddress(MANIFEST_OBJECT_KEY, "_seed", address(0));
            }
        } else {
            // `vm.serializeAddress` requires at least one write before it will
            // emit a valid object. We seed with a sentinel address(0) under
            // a reserved key so subsequent writes have a base to extend.
            manifestJson = vm.serializeAddress(MANIFEST_OBJECT_KEY, "_seed", address(0));
        }
    }

    /// @notice Resolves the CREATE2 factory address from the env and caches it
    ///         for use by `_deployUupsCreate2` and `_deployContractCreate2`.
    /// @dev Reverts hard if the env var is unset or the address has no code,
    ///      because every downstream deploy depends on the factory existing.
    ///      `run.sh` is responsible for bootstrapping the factory and
    ///      exporting `CREATE2_FACTORY` before invoking the stage.
    function initFactory() internal {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        address factory = vm.envAddress(CREATE2_FACTORY_ENV);
        require(factory != address(0), "CREATE2_FACTORY unset");
        require(factory.code.length != 0, "CREATE2_FACTORY: no code at address");
        create2Factory = factory;
        vm.label(factory, "Create2Factory");
    }

    /// @notice Appends a single `name => address` entry to the in-memory manifest.
    /// @dev Overwrites any existing entry under the same name. Stages should
    ///      not reuse names across contracts; the wire stage relies on stable
    ///      naming to look up prior-stage addresses.
    /// @param name Label under which the address is recorded.
    /// @param addr Proxy or contract address to record.
    function logDeployment(string memory name, address addr) internal {
        _requireContract(name, addr);
        manifestJson = vm.serializeAddress(MANIFEST_OBJECT_KEY, name, addr);
    }

    /// @notice Writes the accumulated manifest to disk. Idempotent within a
    ///         stage (safe to call once at the end of `run()`).
    function saveDeployments() internal {
        string[] memory mkdirInputs = new string[](3);
        mkdirInputs[0] = "mkdir";
        mkdirInputs[1] = "-p";
        mkdirInputs[2] = _parentDirectory(manifestPath);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.ffi(mkdirInputs);

        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.writeFile(manifestPath, manifestJson);
    }

    /// @notice Reads an address recorded by a prior stage from the manifest on
    ///         disk. Useful for wire-up stages that must see every proxy the
    ///         earlier stages deployed.
    /// @dev Reverts if the name is not present. Callers should call
    ///      `initDeployment` first so the manifest path is resolved.
    /// @param name The label under which the target address was recorded.
    /// @return addr The recorded address.
    function _readAddress(string memory name) internal view returns (address addr) {
        string memory key = string.concat(".", name);
        addr = vm.parseJsonAddress(manifestJson, key);
        _requireContract(name, addr);
    }

    function _requireContract(string memory name, address addr) internal view {
        require(addr != address(0), string.concat(name, ": zero address"));
        require(addr.code.length != 0, string.concat(name, ": no code"));
    }

    /// @notice Deploys a UUPS implementation + ERC1967 proxy through the
    ///         singleton CREATE2 factory, runs OZ upgrade-safety validation on
    ///         the implementation, labels the result, and records the proxy
    ///         on the manifest.
    /// @dev Salts are derived from `(role, version)` so the same protocol
    ///      contract gets the same proxy address on every chain (given the
    ///      factory is itself at a fixed address — see `Create2Factory` docs).
    ///      The implementation salt is derived from the proxy salt so bumping
    ///      the proxy version also gets a fresh implementation address
    ///      without callers having to track two version numbers.
    ///
    ///      Implementation is deployed *before* the proxy because
    ///      `ERC1967Proxy`'s constructor immediately delegatecalls into the
    ///      implementation to run the initializer; an empty target would
    ///      revert in `_upgradeToAndCall`.
    /// @param owner Broadcasting account; becomes the proxy owner.
    /// @param artefact Fully-qualified artefact name (`File.sol:Contract`).
    /// @param initialiserCalldata ABI-encoded initialiser call.
    /// @param role Short role identifier such as `"registry"` or `"registrar"`
    ///        — combined with `version` and the project salt prefix to form the
    ///        per-contract salt.
    /// @param version Per-contract version, embedded in the salt. Start at 1;
    ///        bump only when intentionally re-deploying to a fresh address.
    /// @param label Trace / manifest identifier.
    /// @return proxy Address of the deployed UUPS proxy.
    function _deployUupsCreate2(
        address owner,
        string memory artefact,
        bytes memory initialiserCalldata,
        string memory role,
        uint256 version,
        string memory label
    )
        internal
        returns (address proxy)
    {
        require(create2Factory != address(0), "Create2Factory not initialised");

        // Keep the full upgrade-safety check the original
        // `Upgrades.deployUUPSProxy` gave us. Validation is purely an FFI
        // call against build artefacts, no broadcast needed.
        Options memory opts;
        Upgrades.validateImplementation(artefact, opts);

        bytes32 proxySalt = _saltFor(role, version);
        bytes32 implSalt = keccak256(abi.encodePacked(proxySalt, ":impl"));

        // forge-lint: disable-next-line(unsafe-cheatcode)
        bytes memory implInitCode = vm.getCode(artefact);
        Create2Factory factory = Create2Factory(create2Factory);

        vm.startBroadcast(owner);
        address impl = factory.deploy(implSalt, implInitCode);
        bytes memory proxyInitCode = abi.encodePacked(
            type(ERC1967Proxy).creationCode, abi.encode(impl, initialiserCalldata)
        );
        proxy = factory.deploy(proxySalt, proxyInitCode);
        vm.stopBroadcast();

        vm.label(impl, string.concat(label, ":impl"));
        vm.label(proxy, label);
        logDeployment(label, proxy);
    }

    /// @notice Deploys a plain (non-proxy) contract through the singleton
    ///         CREATE2 factory and records it on the manifest.
    /// @dev Used by the deploy stages for the small set of utility contracts
    ///      (`StoreFactory`, `Multicall3`, `RootGatewayDispatcher`) that the
    ///      protocol pulls in without an upgrade story. Determinism only
    ///      holds when every address in `constructorArgs` is itself
    ///      CREATE2-derived through this factory.
    /// @param owner Broadcasting account.
    /// @param artefact Fully-qualified artefact name (`File.sol:Contract`).
    /// @param constructorArgs ABI-encoded constructor arguments; pass `""` for
    ///        contracts with no constructor params.
    /// @param role Short role identifier — same scheme as `_deployUupsCreate2`.
    /// @param version Per-contract version. Bump only when intentionally
    ///        re-deploying to a fresh address.
    /// @param label Trace / manifest identifier.
    /// @return deployed Address of the deployed contract.
    function _deployContractCreate2(
        address owner,
        string memory artefact,
        bytes memory constructorArgs,
        string memory role,
        uint256 version,
        string memory label
    )
        internal
        returns (address deployed)
    {
        require(create2Factory != address(0), "Create2Factory not initialised");

        bytes32 salt = _saltFor(role, version);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        bytes memory initCode = abi.encodePacked(vm.getCode(artefact), constructorArgs);

        vm.startBroadcast(owner);
        deployed = Create2Factory(create2Factory).deploy(salt, initCode);
        vm.stopBroadcast();

        vm.label(deployed, label);
        logDeployment(label, deployed);
    }

    /// @notice Derives the per-contract CREATE2 salt for `(role, version)`.
    /// @dev Format is `keccak256("dotns:<role>:v<version>")`. Kept as a helper
    ///      so call sites stay declarative — they pass role + version, never
    ///      raw bytes32 — and so the salt scheme can evolve in one place.
    function _saltFor(string memory role, uint256 version) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(SALT_PREFIX, role, ":v", Strings.toString(version)));
    }

    function _deploymentPath(
        string memory subdirectory,
        string memory filename
    )
        private
        pure
        returns (string memory)
    {
        return string.concat("./deployments/", subdirectory, "/", filename, ".json");
    }

    function _parentDirectory(string memory path) private pure returns (string memory) {
        bytes memory bytesPath = bytes(path);
        uint256 lastSlash = bytesPath.length;
        for (uint256 i = bytesPath.length; i > 0; --i) {
            if (bytesPath[i - 1] == 0x2f) {
                lastSlash = i - 1;
                break;
            }
        }
        bytes memory parent = new bytes(lastSlash);
        for (uint256 i = 0; i < lastSlash; ++i) {
            parent[i] = bytesPath[i];
        }
        return string(parent);
    }
}
