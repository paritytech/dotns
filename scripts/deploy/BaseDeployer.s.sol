// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
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
        _pinBuildInfo();
        // forge-lint: disable-next-line(unsafe-cheatcode)
        address factory = vm.envAddress(CREATE2_FACTORY_ENV);
        require(factory != address(0), "CREATE2_FACTORY unset");
        require(factory.code.length != 0, "CREATE2_FACTORY: no code at address");
        create2Factory = factory;
        vm.label(factory, "Create2Factory");
    }

    /// @notice Removes per-stage `forge script` build-info files so the OZ
    ///         upgrade-safety validator only sees the full build-info produced
    ///         by `forge build`.
    /// @dev `forge script` recompiles with a narrower source graph and writes
    ///      a new build-info file whose `outputSelection` contains empty
    ///      entries for files served from foundry's incremental cache. The OZ
    ///      upgrades-core CLI iterates every file in `out/build-info/` and
    ///      rejects any one with an empty entry — even when the contract under
    ///      validation lives in a different, well-formed file. We side-step
    ///      the validator's directory scan by keeping only the good file.
    ///      `run.sh` records the good path in `DOTNS_GOOD_BUILD_INFO`; when
    ///      unset (e.g. running a stage by hand) this helper is a no-op so the
    ///      script remains usable outside the pipeline.
    function _pinBuildInfo() internal {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory good = vm.envOr("DOTNS_GOOD_BUILD_INFO", string(""));
        if (bytes(good).length == 0) return;

        string[] memory inputs = new string[](3);
        inputs[0] = "bash";
        inputs[1] = "-c";
        inputs[2] = string.concat(
            "find out/build-info -maxdepth 1 -type f -name '*.json' ! -path ",
            _shellQuote(good),
            " -delete"
        );
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.ffi(inputs);
    }

    /// @notice Wraps `s` in single quotes for safe interpolation into a `bash
    ///         -c` command line.
    /// @dev Single-quote-aware escape: any embedded single quote is replaced
    ///      with the standard `'\''` close-open-escape sequence.
    function _shellQuote(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(b.length * 4 + 2);
        uint256 j = 0;
        out[j++] = "'";
        for (uint256 i = 0; i < b.length; ++i) {
            if (b[i] == "'") {
                out[j++] = "'";
                out[j++] = "\\";
                out[j++] = "'";
                out[j++] = "'";
            } else {
                out[j++] = b[i];
            }
        }
        out[j++] = "'";
        bytes memory trimmed = new bytes(j);
        for (uint256 k = 0; k < j; ++k) trimmed[k] = out[k];
        return string(trimmed);
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
    /// @param version Per-contract version, embedded in the salt. Start at 1.
    ///        A redeploy from unchanged init code is reattached automatically
    ///        (`computeAddress` + code-length check), so bump the version only
    ///        when you deliberately want a fresh address despite identical
    ///        init code.
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

        address impl = factory.computeAddress(implSalt, keccak256(implInitCode));
        bytes memory proxyInitCode = abi.encodePacked(
            type(ERC1967Proxy).creationCode, abi.encode(impl, initialiserCalldata)
        );
        proxy = factory.computeAddress(proxySalt, keccak256(proxyInitCode));

        // Reuse-if-exists: a CREATE2 address fully captures its init code, so
        // any code already at `impl` or `proxy` must have been deployed from
        // the exact same bytecode this stage would broadcast. Reattaching is
        // therefore equivalent to redeploying — and skipping the redundant tx
        // avoids the `CreateCollision` that CREATE2 raises on the second
        // attempt. Only broadcast the pieces that are missing.
        bool deployImpl = impl.code.length == 0;
        bool deployProxy = proxy.code.length == 0;

        if (deployImpl || deployProxy) {
            vm.startBroadcast(owner);
            if (deployImpl) {
                require(
                    factory.deploy(implSalt, implInitCode) == impl,
                    "Create2Factory: impl address mismatch"
                );
            }
            if (deployProxy) {
                require(
                    factory.deploy(proxySalt, proxyInitCode) == proxy,
                    "Create2Factory: proxy address mismatch"
                );
            }
            vm.stopBroadcast();
        }
        if (!deployImpl) console.log(string.concat("Reusing ", label, ":impl at"), impl);
        if (!deployProxy) console.log(string.concat("Reusing ", label, " at"), proxy);

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
    /// @param version Per-contract version. Same reattach-on-match semantics
    ///        as `_deployUupsCreate2`; bump only when you deliberately want a
    ///        fresh address despite identical init code.
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
        Create2Factory factory = Create2Factory(create2Factory);
        deployed = factory.computeAddress(salt, keccak256(initCode));

        // Reuse-if-exists: see `_deployUupsCreate2` for the safety argument.
        if (deployed.code.length == 0) {
            vm.startBroadcast(owner);
            require(
                factory.deploy(salt, initCode) == deployed,
                "Create2Factory: address mismatch"
            );
            vm.stopBroadcast();
        } else {
            console.log(string.concat("Reusing ", label, " at"), deployed);
        }

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
