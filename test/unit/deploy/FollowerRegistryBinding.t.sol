// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: © 2026 Parity Technologies
pragma solidity ^0.8.34;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {WireDeployments} from "../../../scripts/deploy/WireDeployments.s.sol";
import {DotnsResolver} from "../../../contracts/resolvers/DotnsResolver.sol";
import {DotnsCostModelRegistry} from "../../../contracts/pop/DotnsCostModelRegistry.sol";
import {IDotnsProtocolRegistry} from "../../../contracts/registry/IDotnsProtocolRegistry.sol";

contract WireBindingHarness is WireDeployments {
    function verifyDeployment(Addresses memory addr, address expectedOwner) external view {
        _verifyDeployment(addr, expectedOwner);
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
