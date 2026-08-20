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
        bytes memory initData = abi.encodeCall(DotnsProtocolRegistry.initialize, ("dot"));
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
            abi.encodeCall(DotnsProtocolRegistry.initialize, ("dot")),
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
        bytes memory initData = abi.encodeCall(DotnsProtocolRegistry.initialize, ("dot"));
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
            abi.encodeCall(DotnsProtocolRegistry.initialize, ("dot")),
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
            abi.encodeCall(DotnsProtocolRegistry.initialize, ("dot")),
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
            abi.encodeCall(DotnsRegistrar.initialize, ("Dotns", "Dotns", registry)),
            "DotnsRegistrar"
        );

        addr.reverseResolver = deployer.deployUups(
            owner,
            "DotnsReverseResolver.sol:DotnsReverseResolver",
            abi.encodeCall(DotnsReverseResolver.initialize, (registry)),
            "DotnsReverseResolver"
        );

        addr.registry = deployer.deployUups(
            owner,
            "DotnsRegistry.sol:DotnsRegistry",
            abi.encodeCall(DotnsRegistry.initialize, (registry)),
            "DotnsRegistry"
        );

        assertEq(DotnsProtocolRegistry(addr.protocolRegistry).owner(), owner, "registry owner");
        assertEq(DotnsRegistrar(addr.registrar).owner(), owner, "registrar owner");
        assertEq(StoreFactory(addr.storeFactory).owner(), owner, "factory owner");
    }
}
