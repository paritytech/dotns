// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {Create3Factory} from "../../../contracts/deploy/Create3Factory.sol";
import {DotnsRegistrar} from "../../../contracts/registrars/DotnsRegistrar.sol";
import {DotnsRegistry} from "../../../contracts/registry/DotnsRegistry.sol";
import {DotnsProtocolRegistry} from "../../../contracts/registry/DotnsProtocolRegistry.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";
import {DotnsReverseResolver} from "../../../contracts/resolvers/DotnsReverseResolver.sol";
import {StoreFactory} from "../../../contracts/store/StoreFactory.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";

import {DeterministicDeploymentHarness} from "./DeterministicDeploymentHarness.t.sol";

contract DeterministicDeploymentTest is Test {
    DeterministicDeploymentHarness private deployer;
    Create3Factory private factory;
    address private owner;

    struct CoreAddresses {
        address protocolRegistry;
        address multicall3;
        address storeFactory;
        address registrar;
        address reverseResolver;
        address registry;
    }

    function setUp() public {
        deployer = new DeterministicDeploymentHarness();
        owner = makeAddr("deterministic-owner");
        vm.deal(owner, 100 ether);
        deployer.initManifest();
        // Mirror DeployCore: bootstrap the factory and prime it as the override
        // so the protocol registry can be deployed through it.
        factory = Create3Factory(payable(deployer.bootstrapCreate3Factory(owner)));
    }

    /// @notice The #260 property: an occupied CREATE3 address holding code this run would not
    ///         have deployed is a hard failure, not an adoption.
    /// @dev Squatting is free. `Create3Factory.deploy` is permissionless and the salts are a
    ///      pure function of public constants, so anyone can occupy a dotNS address in advance.
    ///      Adopting it would wire a foreign contract into the protocol registry and record it
    ///      in the manifest as ours, and the CREATE3 slot can never be reclaimed.
    function test_foreignOccupantIsRejectedRatherThanAdopted() public {
        bytes32 salt = deployer.create3Salt("Multicall3", "contract");

        vm.prank(owner);
        factory.deploy(salt, type(Squatter).creationCode);

        _assertAdoptionRejected("Multicall3.sol:Multicall3", "", "Multicall3");
    }

    /// @notice The same rejection applies to an artefact carrying constructor-set immutables,
    ///         which is the case the check cannot answer by codehash alone.
    /// @dev `StoreFactory` bakes its beacon addresses into runtime code, so two honest deploys
    ///      differ. The check masks the immutable ranges rather than comparing lengths: a length
    ///      comparison accepts any occupant padded to the same size.
    function test_foreignOccupantIsRejectedForAnImmutableCarryingArtefact() public {
        bytes32 salt = deployer.create3Salt("StoreFactory", "contract");

        vm.prank(owner);
        factory.deploy(salt, type(Squatter).creationCode);

        address protocolRegistry = address(new DotnsProtocolRegistry());
        _assertAdoptionRejected(
            "StoreFactory.sol:StoreFactory", abi.encode(protocolRegistry, owner), "StoreFactory"
        );
    }

    /// @notice A real `StoreFactory` deployed against an attacker's constructor arguments is
    ///         rejected, not adopted.
    /// @dev The case bytecode comparison alone cannot answer. The occupant is the genuine
    ///      artefact, so its length and shape match; only the values its constructor baked in
    ///      differ. Comparing against a reference built with this run's arguments catches it,
    ///      while the beacons `StoreFactory` deploys itself vary on every honest deploy and are
    ///      necessarily skipped.
    function test_sameArtefactWithForeignConstructorArgsIsRejected() public {
        address attacker = makeAddr("attacker");
        address realRegistry = address(new DotnsProtocolRegistry());
        address foreignRegistry = address(new DotnsProtocolRegistry());

        bytes32 salt = deployer.create3Salt("StoreFactory", "contract");
        vm.prank(attacker);
        factory.deploy(
            salt,
            abi.encodePacked(type(StoreFactory).creationCode, abi.encode(foreignRegistry, attacker))
        );

        _assertAdoptionRejected(
            "StoreFactory.sol:StoreFactory", abi.encode(realRegistry, owner), "StoreFactory"
        );
    }

    /// @notice A resumed run adopts its own earlier deployment of an artefact carrying
    ///         immutables. The reject cases below exercise the reference-diff path; this is the
    ///         one that proves it still says yes to an honest resume.
    /// @dev `StoreFactory` is the demanding case: its constructor deploys fresh beacons every
    ///      time, so the second run's reference copies differ from the occupant exactly where
    ///      the comparison must skip. A check that compared those bytes would force a salt bump
    ///      on every interrupted run.
    function test_resumeAdoptsAnImmutableCarryingArtefact() public {
        address protocolRegistry = address(new DotnsProtocolRegistry());
        bytes memory constructorData = abi.encode(protocolRegistry, owner);

        address first = deployer.deployCreate3(
            owner, "StoreFactory.sol:StoreFactory", constructorData, "StoreFactory"
        );
        address second = deployer.deployCreate3(
            owner, "StoreFactory.sol:StoreFactory", constructorData, "StoreFactory"
        );

        assertEq(second, first, "an honest resume of an immutable artefact was not adopted");
    }

    /// @notice A resumed run still adopts its own earlier deployment. Guards the other direction:
    ///         a check strict enough to reject a squat must not reject the honest resume, or
    ///         every interrupted run would need a salt bump to recover.
    function test_resumeAdoptsThisRunsOwnDeployment() public {
        address first = deployer.deployCreate3(owner, "Multicall3.sol:Multicall3", "", "Multicall3");
        address second =
            deployer.deployCreate3(owner, "Multicall3.sol:Multicall3", "", "Multicall3");

        assertEq(second, first, "a resumed run did not adopt its own deployment");
    }

    /// @notice Asserts the pipeline refuses to adopt whatever currently occupies the address.
    /// @dev Checks the reason rather than taking any revert: the occupancy check is one `require`
    ///      among several in the deploy path, so a bare `expectRevert` would pass just as happily
    ///      on a broken fixture that reverted for an unrelated reason. The byte offset in the
    ///      mismatch message shifts with any recompile, so the assertion pins the parts that
    ///      identify the check instead of the whole string.
    function _assertAdoptionRejected(
        string memory artefact,
        bytes memory constructorData,
        string memory label
    )
        private
    {
        try deployer.deployCreate3(owner, artefact, constructorData, label) returns (address) {
            fail("the occupant was adopted instead of rejected");
        } catch Error(string memory reason) {
            assertTrue(
                _contains(reason, "Refusing to adopt code this run did not deploy."),
                string.concat("reverted for an unrelated reason: ", reason)
            );
            assertTrue(
                _contains(reason, artefact),
                string.concat("revert did not name the artefact: ", reason)
            );
        }
    }

    /// @notice True when `haystack` contains `needle`.
    function _contains(string memory haystack, string memory needle) private pure returns (bool) {
        bytes memory outer = bytes(haystack);
        bytes memory inner = bytes(needle);
        if (inner.length == 0 || inner.length > outer.length) return false;

        for (uint256 i; i <= outer.length - inner.length; ++i) {
            bool matched = true;
            for (uint256 j; j < inner.length; ++j) {
                if (outer[i + j] != inner[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }

    function test_coreDeploymentAddressesStayTheSameAcrossChainIds() public {
        uint256 baseline = vm.snapshotState();

        vm.chainId(420420417);
        CoreAddresses memory paseo = _deployCore();

        vm.revertToState(baseline);
        baseline = vm.snapshotState();

        vm.chainId(420420422);
        CoreAddresses memory passetHub = _deployCore();

        assertEq(passetHub.protocolRegistry, paseo.protocolRegistry, "protocol registry");
        assertEq(passetHub.multicall3, paseo.multicall3, "multicall3");
        assertEq(passetHub.storeFactory, paseo.storeFactory, "store factory");
        assertEq(passetHub.registrar, paseo.registrar, "registrar");
        assertEq(passetHub.reverseResolver, paseo.reverseResolver, "reverse resolver");
        assertEq(passetHub.registry, paseo.registry, "registry");

        vm.revertToState(baseline);
    }

    function test_predictionsMatchCreate3Deployments() public {
        bytes memory initData = abi.encodeCall(DotnsProtocolRegistry.initialize, (owner, "dot"));
        address predicted = deployer.predictCreate3("DotnsProtocolRegistry", "proxy");

        address deployed = deployer.deployUups(
            owner,
            "DotnsProtocolRegistry.sol:DotnsProtocolRegistry",
            initData,
            "DotnsProtocolRegistry"
        );

        assertEq(deployed, predicted, "predicted proxy");
        assertEq(DotnsProtocolRegistry(deployed).owner(), owner, "proxy owner");
    }

    function test_create3FactoryResolvesFromProtocolRegistry() public {
        // Mirror DeployCore: deploy the protocol registry through the bootstrapped
        // factory, then record the factory on the registry.
        address protocolRegistry = deployer.deployUups(
            owner,
            "DotnsProtocolRegistry.sol:DotnsProtocolRegistry",
            abi.encodeCall(DotnsProtocolRegistry.initialize, (owner, "dot")),
            "DotnsProtocolRegistry"
        );
        deployer.registerCreate3Factory(owner, protocolRegistry, address(factory));

        assertEq(
            IDotnsProtocolRegistry(protocolRegistry).get(DotnsConstants.CREATE3_FACTORY),
            address(factory),
            "factory recorded on protocol registry"
        );

        // Simulate a later pipeline stage: clear the override so the factory must
        // be resolved from the protocol registry recorded in the manifest.
        deployer.setCreate3Factory(address(0));

        address predicted = deployer.predictCreate3("Multicall3", "contract");
        address deployed =
            deployer.deployCreate3(owner, "Multicall3.sol:Multicall3", bytes(""), "Multicall3");
        assertEq(deployed, predicted, "registry-resolved deploy matches prediction");
    }

    function test_predictionsMatchForNonProxyDeploys() public {
        address predictedPaseo = _predictMulticall3On(420420417);
        address deployedPaseo = _deployMulticall3On(420420417);
        assertEq(deployedPaseo, predictedPaseo, "paseo: prediction matches deploy");

        address predictedPassetHub = _predictMulticall3On(420420422);
        address deployedPassetHub = _deployMulticall3On(420420422);
        assertEq(deployedPassetHub, predictedPassetHub, "passetHub: prediction matches deploy");

        assertEq(deployedPassetHub, deployedPaseo, "deploy stable across chains");
    }

    function test_addressesIdenticalAcrossDeployers() public {
        address bob = makeAddr("bob-deployer");
        vm.deal(bob, 100 ether);

        address paseoOwner = _deployRegistryOn(420420417, owner);
        address paseoBob = _deployRegistryOn(420420417, bob);
        address passetHubOwner = _deployRegistryOn(420420422, owner);
        address passetHubBob = _deployRegistryOn(420420422, bob);

        assertEq(paseoBob, paseoOwner, "paseo: different deployer, same address");
        assertEq(passetHubBob, paseoOwner, "passetHub: different deployer, same address");
        assertEq(passetHubOwner, paseoOwner, "same deployer, different chain");
    }

    function test_addressesStableAcrossSequentialRuns() public {
        address paseoFirst = _deployRegistryOn(420420417, owner);
        address paseoSecond = _deployRegistryOn(420420417, owner);
        address passetHubFirst = _deployRegistryOn(420420422, owner);
        address passetHubSecond = _deployRegistryOn(420420422, owner);

        assertEq(paseoSecond, paseoFirst, "paseo: sequential run, same address");
        assertEq(passetHubSecond, passetHubFirst, "passetHub: sequential run, same address");
        assertEq(passetHubFirst, paseoFirst, "sequential run stable across chains");
    }

    function test_reusedFactoryMakesAddressesDeployerIndependent() public {
        // A CREATE3 factory deployed once, independently of any pipeline run.
        Create3Factory shared = new Create3Factory();

        // Two separate deployer runs that reuse the same factory must predict
        // the same address, even though neither minted it.
        DeterministicDeploymentHarness runA = new DeterministicDeploymentHarness();
        runA.initManifest();
        runA.adoptCreate3Factory(address(shared));

        DeterministicDeploymentHarness runB = new DeterministicDeploymentHarness();
        runB.initManifest();
        runB.adoptCreate3Factory(address(shared));

        assertEq(
            runA.predictCreate3("DotnsRegistrar", "proxy"),
            runB.predictCreate3("DotnsRegistrar", "proxy"),
            "reused factory: identical address across deployers"
        );

        // Minting a fresh factory instead lands the same contract elsewhere,
        // which is exactly the drift reuse avoids across chain resets.
        DeterministicDeploymentHarness minting = new DeterministicDeploymentHarness();
        minting.initManifest();
        minting.bootstrapCreate3Factory(owner);
        assertTrue(
            minting.predictCreate3("DotnsRegistrar", "proxy")
                != runA.predictCreate3("DotnsRegistrar", "proxy"),
            "freshly minted factory yields a different address"
        );
    }

    function test_ensureReusesConfiguredFactory() public {
        Create3Factory preDeployed = new Create3Factory();
        vm.setEnv("CREATE3_FACTORY", vm.toString(address(preDeployed)));

        DeterministicDeploymentHarness reuse = new DeterministicDeploymentHarness();
        reuse.initManifest();
        assertEq(
            reuse.ensureCreate3Factory(owner),
            address(preDeployed),
            "ensure reuses the configured factory"
        );

        // Reset so later tests mint their own factory.
        vm.setEnv("CREATE3_FACTORY", vm.toString(address(0)));
    }

    function test_adoptRevertsWhenFactoryHasNoCode() public {
        DeterministicDeploymentHarness fresh = new DeterministicDeploymentHarness();
        fresh.initManifest();
        vm.expectRevert(bytes("Create3Factory: no code at factory address"));
        fresh.adoptCreate3Factory(makeAddr("not-a-factory"));
    }

    function test_reDeployAdoptsAnExistingContract() public {
        // A resumed run re-deploys a non-upgradeable contract already on-chain:
        // it must adopt the existing address rather than revert.
        address first =
            deployer.deployCreate3(owner, "Multicall3.sol:Multicall3", bytes(""), "Multicall3");
        address second =
            deployer.deployCreate3(owner, "Multicall3.sol:Multicall3", bytes(""), "Multicall3");
        assertEq(second, first, "re-run adopts the existing contract");
    }

    function test_reDeployAdoptsProxyWithoutReinitialising() public {
        bytes memory initData = abi.encodeCall(DotnsProtocolRegistry.initialize, (owner, "dot"));
        address first = deployer.deployUups(
            owner,
            "DotnsProtocolRegistry.sol:DotnsProtocolRegistry",
            initData,
            "DotnsProtocolRegistry"
        );
        // A resumed run adopts the proxy and must NOT call initialize again, which
        // would revert on an already-initialised proxy.
        address second = deployer.deployUups(
            owner,
            "DotnsProtocolRegistry.sol:DotnsProtocolRegistry",
            initData,
            "DotnsProtocolRegistry"
        );
        assertEq(second, first, "re-run adopts the existing proxy");
        assertEq(DotnsProtocolRegistry(second).owner(), owner, "proxy stays initialised");
    }

    function _deployRegistry(address deployerAccount) private returns (address) {
        return deployer.deployUups(
            deployerAccount,
            "DotnsProtocolRegistry.sol:DotnsProtocolRegistry",
            abi.encodeCall(DotnsProtocolRegistry.initialize, (owner, "dot")),
            "DotnsProtocolRegistry"
        );
    }

    function _deployRegistryOn(
        uint256 chainId,
        address deployerAccount
    )
        private
        returns (address result)
    {
        uint256 snap = vm.snapshotState();
        vm.chainId(chainId);
        result = _deployRegistry(deployerAccount);
        vm.revertToState(snap);
    }

    function _predictMulticall3On(uint256 chainId) private returns (address result) {
        uint256 snap = vm.snapshotState();
        vm.chainId(chainId);
        result = deployer.predictCreate3("Multicall3", "contract");
        vm.revertToState(snap);
    }

    function _deployMulticall3On(uint256 chainId) private returns (address result) {
        uint256 snap = vm.snapshotState();
        vm.chainId(chainId);
        result = deployer.deployCreate3(owner, "Multicall3.sol:Multicall3", bytes(""), "Multicall3");
        vm.revertToState(snap);
    }

    function _deployCore() private returns (CoreAddresses memory addr) {
        addr.protocolRegistry = deployer.deployUups(
            owner,
            "DotnsProtocolRegistry.sol:DotnsProtocolRegistry",
            abi.encodeCall(DotnsProtocolRegistry.initialize, (owner, "dot")),
            "DotnsProtocolRegistry"
        );

        addr.multicall3 =
            deployer.deployCreate3(owner, "Multicall3.sol:Multicall3", bytes(""), "Multicall3");

        addr.storeFactory = deployer.deployCreate3(
            owner,
            "StoreFactory.sol:StoreFactory",
            abi.encode(addr.protocolRegistry, owner),
            "StoreFactory"
        );

        IDotnsProtocolRegistry registry = IDotnsProtocolRegistry(addr.protocolRegistry);

        addr.registrar = deployer.deployUups(
            owner,
            "DotnsRegistrar.sol:DotnsRegistrar",
            abi.encodeCall(DotnsRegistrar.initialize, (owner, "Dotns", "Dotns", registry)),
            "DotnsRegistrar"
        );

        addr.reverseResolver = deployer.deployUups(
            owner,
            "DotnsReverseResolver.sol:DotnsReverseResolver",
            abi.encodeCall(DotnsReverseResolver.initialize, (owner, registry)),
            "DotnsReverseResolver"
        );

        addr.registry = deployer.deployUups(
            owner,
            "DotnsRegistry.sol:DotnsRegistry",
            abi.encodeCall(DotnsRegistry.initialize, (owner, registry)),
            "DotnsRegistry"
        );

        assertEq(DotnsProtocolRegistry(addr.protocolRegistry).owner(), owner, "registry owner");
        assertEq(DotnsRegistrar(addr.registrar).owner(), owner, "registrar owner");
        assertEq(StoreFactory(addr.storeFactory).owner(), owner, "factory owner");
    }
}

/// @notice Arbitrary code standing at a dotNS CREATE3 address. Represents anything an attacker
///         might park there; the pipeline must refuse it whatever it is.
contract Squatter {
    address public immutable OWNER = msg.sender;

    function hello() external pure returns (uint256) {
        return 42;
    }
}
