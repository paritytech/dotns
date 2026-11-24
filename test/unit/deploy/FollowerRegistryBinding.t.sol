// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {WireDeployments} from "../../../scripts/deploy/WireDeployments.s.sol";
import {DotnsDeployer} from "../../../scripts/deploy/DotnsDeployer.s.sol";
import {DotnsProtocolRegistry} from "../../../contracts/registry/DotnsProtocolRegistry.sol";
import {DotnsResolver} from "../../../contracts/resolvers/DotnsResolver.sol";
import {DotnsCostModelRegistry} from "../../../contracts/pop/DotnsCostModelRegistry.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";

contract WireBindingHarness is WireDeployments {
    function verifyDeployment(Addresses memory addr, address expectedOwner) external view {
        _verifyDeployment(addr, expectedOwner);
    }
}

contract DeployerBindingHarness is DotnsDeployer {
    function bind(DotnsProtocolRegistry registry) external {
        protocolRegistry = registry;
    }

    function verifyOwnership(address expectedOwner) external view {
        _verifyOwnership(expectedOwner);
    }

    function verifyRegistryPointers(Deployment memory deployment) external view {
        _verifyRegistryPointers(deployment);
    }
}

/// @notice Answers `owner()` with whatever account it was given, as a foreign registry planted
///         behind a squatted proxy would.
contract ForeignRegistry {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }
}

/// @notice The wire stage binds every contract to the deployment's protocol registry: a genuine
///         proxy initialised against a foreign registry fails verification even though its
///         `owner()` reports the expected owner.
contract FollowerRegistryBindingTests is BaseDotns {
    WireBindingHarness private harness;
    ForeignRegistry private foreign;

    function setUp() public override {
        super.setUp();
        harness = new WireBindingHarness();
        foreign = new ForeignRegistry(owner);
    }

    function test_revert_a_follower_bound_to_a_foreign_registry_fails_verification() public {
        address squatted = address(
            new ERC1967Proxy(
                address(new DotnsResolver()),
                abi.encodeCall(DotnsResolver.initialize, (IDotnsProtocolRegistry(address(foreign))))
            )
        );
        assertEq(DotnsResolver(squatted).owner(), owner);

        WireDeployments.Addresses memory addr = _addresses();
        addr.resolver = squatted;

        vm.expectRevert(bytes("Resolver: bound to a foreign protocol registry"));
        harness.verifyDeployment(addr, owner);
    }

    function test_revert_a_cost_model_registry_bound_to_a_foreign_registry_fails_verification()
        public
    {
        DotnsCostModelRegistry squatted =
            new DotnsCostModelRegistry(IDotnsProtocolRegistry(address(foreign)));
        assertEq(squatted.owner(), owner);

        WireDeployments.Addresses memory addr = _addresses();
        addr.costModelRegistry = address(squatted);

        vm.expectRevert(bytes("CostModelRegistry: bound to a foreign protocol registry"));
        harness.verifyDeployment(addr, owner);
    }

    function test_revert_a_wrong_protocol_registry_owner_fails_verification() public {
        vm.expectRevert(bytes("ProtocolRegistry: wrong owner"));
        harness.verifyDeployment(_addresses(), makeAddr("someoneElse"));
    }

    function test_revert_the_single_run_deployer_rejects_a_foreign_cost_model_registry() public {
        DeployerBindingHarness deployer = new DeployerBindingHarness();
        deployer.bind(protocolRegistry);
        DotnsDeployer.Deployment memory deployment = _deployment();
        deployer.verifyRegistryPointers(deployment);

        deployment.costModelRegistry =
            address(new DotnsCostModelRegistry(IDotnsProtocolRegistry(address(foreign))));
        vm.expectRevert(bytes("CostModelRegistry: not wired"));
        deployer.verifyRegistryPointers(deployment);
    }

    function test_revert_the_single_run_deployer_rejects_a_foreign_follower() public {
        DeployerBindingHarness deployer = new DeployerBindingHarness();
        deployer.bind(protocolRegistry);
        DotnsDeployer.Deployment memory deployment = _deployment();
        deployment.resolver = address(
            new ERC1967Proxy(
                address(new DotnsResolver()),
                abi.encodeCall(DotnsResolver.initialize, (IDotnsProtocolRegistry(address(foreign))))
            )
        );

        vm.expectRevert(bytes("Resolver: not wired"));
        deployer.verifyRegistryPointers(deployment);
    }

    function test_revert_the_single_run_deployer_checks_the_protocol_registry_owner() public {
        DeployerBindingHarness deployer = new DeployerBindingHarness();
        deployer.bind(protocolRegistry);
        deployer.verifyOwnership(owner);

        vm.expectRevert(bytes("ProtocolRegistry: wrong owner"));
        deployer.verifyOwnership(makeAddr("someoneElse"));
    }

    function _deployment() internal view returns (DotnsDeployer.Deployment memory deployment) {
        deployment.storeFactory = address(storeFactory);
        deployment.registrar = address(dotnsRegistrar);
        deployment.reverseResolver = address(dotnsReverseResolver);
        deployment.registry = address(dotnsRegistry);
        deployment.contentResolver = address(dotnsContentResolver);
        deployment.resolver = address(dotnsResolver);
        deployment.popRules = address(popRules);
        deployment.costModelRegistry = address(costModelRegistry);
        deployment.registrarController = address(dotnsRegistrarController);
        deployment.protocolRegistry = address(protocolRegistry);
        deployment.nameEscrow = address(dotnsNameEscrow);
        deployment.popResolver = address(dotnsPopResolver);
        deployment.popController = address(dotnsPopController);
        deployment.popLens = address(dotnsPopLens);
        deployment.nameWhitelist = address(dotnsNameWhitelist);
    }

    function _addresses() internal view returns (WireDeployments.Addresses memory addr) {
        addr.storeFactory = address(storeFactory);
        addr.registrar = address(dotnsRegistrar);
        addr.reverseResolver = address(dotnsReverseResolver);
        addr.registry = address(dotnsRegistry);
        addr.contentResolver = address(dotnsContentResolver);
        addr.resolver = address(dotnsResolver);
        addr.popRules = address(popRules);
        addr.costModelRegistry = address(costModelRegistry);
        addr.registrarController = address(dotnsRegistrarController);
        addr.protocolRegistry = address(protocolRegistry);
        addr.nameEscrow = address(dotnsNameEscrow);
        addr.nameWhitelist = address(dotnsNameWhitelist);
        addr.popResolver = address(dotnsPopResolver);
        addr.popController = address(dotnsPopController);
        addr.popLens = address(dotnsPopLens);
    }
}
