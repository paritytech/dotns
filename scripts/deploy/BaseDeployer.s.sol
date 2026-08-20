// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Create3Factory} from "../../contracts/deploy/Create3Factory.sol";
import {IDotnsProtocolRegistry} from "../../contracts/registry/IDotnsProtocolRegistry.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";
import {DeploymentNetwork} from "./DeploymentNetwork.sol";

/// @title BaseDeployer
/// @notice Shared base for the DotNS deploy pipeline. Each concrete stage
///         script reads the manifest from disk (populated by prior stages),
///         deploys its own proxies in its own forge-script process, and writes
///         the updated manifest back.
/// @dev The pipeline is split across separate `forge script` invocations so
///      each OpenZeppelin upgrade-safety validation runs in a fresh EVM
///      simulation. EVM memory gas is quadratic, and a monolithic script
///      accumulates it across every validator FFI call until the block gas
///      limit is hit. Separate processes side-step the accumulation entirely
///      without skipping any OZ check.
/// @custom:security-contact admin@parity.io
abstract contract BaseDeployer is Script {
    /// @notice JSON object key used internally by the `vm.serializeAddress`
    ///         helper. The value is arbitrary; it only has to be stable across
    ///         successive calls within the same run.
    string internal constant MANIFEST_OBJECT_KEY = "dotns.manifest";

    /// @notice Namespace for all DotNS CREATE3 salts.
    /// @dev Do not include the chain ID: the deployment goal is identical
    ///      addresses for identical bytecode and constructor data on every
    ///      chain. Bump this value only when intentionally moving the whole
    ///      deployment address set.
    string internal constant CREATE3_SALT_NAMESPACE = "dotns.create3.v1";

    /// @notice Optional in-memory override used by tests and custom scripts.
    address private create3FactoryOverride;

    /// @notice In-memory JSON string representing the full deployment manifest
    ///         accumulated across this stage's calls to `logDeployment`.
    string private manifestJson;

    /// @notice Disk path the current stage reads from and writes to. Populated
    ///         by `initDeployment`.
    string private manifestPath;

    /// @notice Resolves the manifest subdirectory for the network being
    ///         deployed to, honouring an explicit `DEPLOYMENT_NETWORK` override.
    /// @dev Distinct chains can present the same `block.chainid` (for example a
    ///      previewnet and a next environment both reached through the local
    ///      ETH-RPC adapter). Chain id alone then aliases their manifests onto
    ///      one file, so a later deploy silently overwrites an earlier one.
    ///      Setting `DEPLOYMENT_NETWORK` names the subdirectory explicitly so
    ///      each upstream keeps its own manifest; when it is unset the mapping
    ///      falls back to the chain-id default in `DeploymentNetwork.folder`.
    ///      The deploy runner exports the same variable so its manifest path
    ///      stays in step with the one resolved here.
    /// @return subdirectory Folder under `deployments/` for the current network.
    function networkFolder() internal view returns (string memory subdirectory) {
        subdirectory = vm.envOr("DEPLOYMENT_NETWORK", DeploymentNetwork.folder(block.chainid));
    }

    /// @notice Resolves the bare TLD label to initialise the protocol registry with.
    /// @dev Read from `DOTNS_TLD` because distinct networks can share one `block.chainid`, so the
    ///      TLD cannot be keyed off the chain id. The operator sets `DOTNS_TLD=paseo` (or `test`,
    ///      `dot`) per deployment; it is required, with no default, so an unset or empty value
    ///      aborts the deploy rather than silently landing the wrong TLD, which no setter can
    ///      correct afterwards. The label is passed straight into
    ///      `DotnsProtocolRegistry.initialize`, which validates it as a single DNS label.
    /// @return label Bare TLD label without the leading dot.
    function tldLabel() internal view returns (string memory label) {
        label = vm.envString("DOTNS_TLD");
        require(
            bytes(label).length != 0, "DOTNS_TLD must be set to a bare TLD label (for example dot)"
        );
    }

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

    /// @notice Deploys a UUPS implementation and ERC1967 proxy through CREATE3
    ///         inside its own broadcast scope, labels the proxy for trace
    ///         readability, and records it on the manifest.
    /// @dev Full OZ upgrade-safety validation runs on every call. The helper
    ///      exists so every stage script shares one canonical deploy shape
    ///      rather than repeating the validation, broadcast, label, and log
    ///      sequence. Salts are derived from a stable DotNS namespace plus the
    ///      manifest label, so addresses stay the same across chains as long as
    ///      the deployer, bytecode, constructor args, and label remain stable.
    /// @param owner Broadcasting account; becomes the proxy owner.
    /// @param artefact Fully-qualified artefact name (`File.sol:Contract`).
    /// @param initialiserCalldata ABI-encoded initialiser call.
    /// @param label Trace / manifest identifier.
    /// @return proxy Address of the deployed UUPS proxy.
    function _broadcastDeployUups(
        address owner,
        string memory artefact,
        bytes memory initialiserCalldata,
        string memory label
    )
        internal
        returns (address proxy)
    {
        Options memory opts;
        Upgrades.validateImplementation(artefact, opts);

        vm.startBroadcast(owner);
        (address implementation,) =
            _deployCreate3(artefact, opts.constructorData, _create3Salt(label, "implementation"));
        bool proxyExisted;
        (proxy, proxyExisted) = _deployCreate3(
            "ERC1967Proxy.sol:ERC1967Proxy",
            abi.encode(implementation, bytes("")),
            _create3Salt(label, "proxy")
        );
        // Initialise only a freshly deployed proxy; an adopted one (a resumed run)
        // is already initialised, and re-initialising would revert.
        if (!proxyExisted && initialiserCalldata.length != 0) {
            (bool ok, bytes memory ret) = proxy.call(initialiserCalldata);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 32), mload(ret))
                }
            }
        } else if (proxyExisted && initialiserCalldata.length != 0) {
            // The proxy keeps the configuration its first deploy set, so every
            // initialiser argument computed for this run is discarded. Values
            // without a setter (such as the TLD) cannot be corrected afterwards,
            // so surface it rather than reporting success.
            console.log("WARNING: adopted existing proxy, initialiser skipped for", label);
            console.log("         on-chain configuration may differ from this run's inputs");
        }
        vm.stopBroadcast();
        vm.label(proxy, label);
        logDeployment(label, proxy);
    }

    /// @notice Deploys a non-upgradeable contract with CREATE3 in a broadcast
    ///         scope, labels it, and records it in the manifest.
    /// @param owner Broadcasting account.
    /// @param artefact Fully-qualified artefact name.
    /// @param constructorData ABI-encoded constructor arguments.
    /// @param label Trace / manifest identifier.
    /// @return deployed Address of the deployed contract.
    function _broadcastDeployCreate3(
        address owner,
        string memory artefact,
        bytes memory constructorData,
        string memory label
    )
        internal
        returns (address deployed)
    {
        vm.startBroadcast(owner);
        (deployed,) = _deployCreate3(artefact, constructorData, _create3Salt(label, "contract"));
        vm.stopBroadcast();
        vm.label(deployed, label);
        logDeployment(label, deployed);
    }

    /// @notice Ensures the CREATE3 factory exists and primes it as the in-memory
    ///         override for the remainder of this process, reusing a pre-deployed
    ///         factory when one is configured.
    /// @dev Every DotNS address is a pure function of the factory address and a
    ///      stable salt, and the factory address is `keccak(deployer, nonce)`. A
    ///      fresh `new Create3Factory()` from a key whose nonce is not fixed
    ///      therefore lands at a new address and shifts every downstream CREATE3
    ///      address with it, which is why a key that also runs upgrades cannot
    ///      keep addresses stable across chain resets. Deploy the factory once
    ///      from a single-purpose key at nonce 0 (see `DeployCreate3Factory`) and
    ///      pass its address as `CREATE3_FACTORY`; every pipeline run then reuses
    ///      that factory instead of minting one, so the shared deployer's nonce
    ///      no longer affects any address. With `CREATE3_FACTORY` unset the
    ///      factory is minted here as before.
    /// @param owner Broadcasting account; deploys the factory only when none is
    ///        configured.
    /// @return factory Address of the reused or freshly deployed CREATE3 factory.
    function _ensureCreate3Factory(address owner) internal returns (address factory) {
        factory = _configuredCreate3Factory();
        if (factory != address(0)) {
            _adoptCreate3Factory(factory);
        } else {
            factory = _bootstrapCreate3Factory(owner);
        }
    }

    /// @notice Returns the pre-deployed CREATE3 factory address supplied through
    ///         the `CREATE3_FACTORY` environment variable, or the zero address
    ///         when the pipeline should mint its own.
    /// @return configured Configured factory address, or `address(0)` when unset.
    function _configuredCreate3Factory() internal view returns (address configured) {
        configured = vm.envOr("CREATE3_FACTORY", address(0));
    }

    /// @notice Mints a fresh CREATE3 factory and primes it as the in-memory
    ///         override for the remainder of this process.
    /// @dev Bootstrap step for the first deploy stage: the factory cannot deploy
    ///      itself, and it must exist before any CREATE3 deploy, including the
    ///      protocol registry's own. The minted address is nonce-derived, so this
    ///      path only reproduces the same address when `owner` is at the same
    ///      nonce as the original deploy; prefer reuse via `_ensureCreate3Factory`
    ///      for stable addresses across resets.
    /// @param owner Broadcasting account; deploys and is recorded as the factory.
    /// @return factory Address of the freshly deployed CREATE3 factory.
    function _bootstrapCreate3Factory(address owner) internal returns (address factory) {
        vm.startBroadcast(owner);
        factory = address(new Create3Factory());
        vm.stopBroadcast();
        console.log("WARNING: minted a nonce-derived CREATE3 factory at", factory);
        console.log(
            "  Its address depends on the deployer nonce and is NOT reproducible across chain"
        );
        console.log(
            "  resets. To pin every DotNS address, set CREATE3_FACTORY (or run deploy:all)."
        );
        _adoptCreate3Factory(factory);
    }

    /// @notice Primes `factory` as the in-memory override, labels it, and records
    ///         it on the manifest. Shared by the reuse and mint paths.
    /// @dev Reverts when `factory` has no code, so a mistyped or wrong-chain
    ///      `CREATE3_FACTORY` fails fast instead of producing a deploy against a
    ///      non-existent factory.
    /// @param factory CREATE3 factory address to adopt for this process.
    function _adoptCreate3Factory(address factory) internal {
        require(factory.code.length != 0, "Create3Factory: no code at factory address");
        _setCreate3Factory(factory);
        vm.label(factory, "Create3Factory");
        logDeployment("Create3Factory", factory);
    }

    /// @notice Records the CREATE3 factory under `DotnsConstants.CREATE3_FACTORY`
    ///         on the protocol registry so every later stage resolves it from the
    ///         registry rather than an environment variable.
    /// @param owner Broadcasting account; must own the protocol registry.
    /// @param protocolRegistry Protocol registry proxy address.
    /// @param factory CREATE3 factory address to record.
    function _registerCreate3Factory(
        address owner,
        address protocolRegistry,
        address factory
    )
        internal
    {
        vm.startBroadcast(owner);
        IDotnsProtocolRegistry(protocolRegistry).set(DotnsConstants.CREATE3_FACTORY, factory);
        vm.stopBroadcast();
    }

    /// @notice Sets the in-memory CREATE3 factory override used by the bootstrap
    ///         stage and tests. Passing `address(0)` clears the override so
    ///         resolution falls back to the protocol registry.
    /// @dev The factory's code is validated at the point of use in
    ///      `_create3Factory`, so this setter accepts any address.
    function _setCreate3Factory(address factory) internal {
        create3FactoryOverride = factory;
    }

    /// @notice Predicts the CREATE3 address used by the deterministic deploy
    ///         helpers for the same inputs.
    function _predictCreate3(
        string memory label,
        string memory kind
    )
        internal
        view
        returns (address predicted)
    {
        predicted = _create3Factory().predict(_create3Salt(label, kind));
    }

    /// @notice Deploys `artefact` at its CREATE3 address, or adopts that address
    ///         when it already has code, so a re-run resumes instead of reverting.
    /// @dev The CREATE3 address is a pure function of the factory and salt, so it
    ///      is identical whether freshly deployed or adopted. `existed` lets
    ///      callers skip one-time steps (such as proxy initialisation) on adoption.
    /// @return deployed The CREATE3 address of the contract.
    /// @return existed True when the target already had code and was adopted.
    function _deployCreate3(
        string memory artefact,
        bytes memory constructorData,
        bytes32 salt
    )
        internal
        returns (address deployed, bool existed)
    {
        address predicted = _create3Factory().predict(salt);
        if (predicted.code.length != 0) {
            return (predicted, true);
        }

        deployed = _create3Factory().deploy(salt, _creationBytecode(artefact, constructorData));
        require(deployed == predicted, string.concat(artefact, ": CREATE3 deploy failed"));
    }

    function _creationBytecode(
        string memory artefact,
        bytes memory constructorData
    )
        internal
        view
        returns (bytes memory)
    {
        return abi.encodePacked(vm.getCode(artefact), constructorData);
    }

    /// @notice Resolves the CREATE3 factory: the in-memory override when set
    ///         (bootstrap stage and tests), otherwise the address recorded under
    ///         `DotnsConstants.CREATE3_FACTORY` on the protocol registry.
    /// @dev Reading the factory from the protocol registry keeps the deterministic
    ///      deploy pipeline self-describing: every stage after the first finds the
    ///      factory through the manifest's protocol registry, so no environment
    ///      variable is required.
    function _create3Factory() internal view returns (Create3Factory factory) {
        address factoryAddress = create3FactoryOverride;
        if (factoryAddress == address(0)) {
            address protocolRegistry = _readAddress("DotnsProtocolRegistry");
            factoryAddress =
                IDotnsProtocolRegistry(protocolRegistry).get(DotnsConstants.CREATE3_FACTORY);
        }
        require(factoryAddress.code.length != 0, "Create3Factory: no code");
        factory = Create3Factory(payable(factoryAddress));
    }

    function _create3Salt(string memory label, string memory kind) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(CREATE3_SALT_NAMESPACE, ":", label, ":", kind));
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
