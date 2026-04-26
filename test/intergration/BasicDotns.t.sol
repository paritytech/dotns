// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns} from "../base/BaseDotns.t.sol";
import {IPopRules} from "../../contracts/pop/IPopRules.sol";
import {IDotnsRegistry} from "../../contracts/registry/IDotnsRegistry.sol";
import {IDotnsRegistrarController} from "../../contracts/registrars/IDotnsRegistrarController.sol";
import {Store} from "../../contracts/store/Store.sol";

contract BasicDotnsIntegration is BaseDotns {
    string internal constant NAME_POPFULL = "waytall1";
    string internal constant NAME_POPLITE = "way2tall01";
    string internal constant NAME_NOSTATUS = "kitesurfing01";

    bytes internal constant CID_A =
        hex"e30101701220aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    bytes internal constant CID_B =
        hex"e30101701220bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    struct FlowParams {
        address nameOwner;
        string name;
        bool reserved;

        string selfSub;
        string otherSub;
        address otherOwner;

        address transferTo;

        string transferRecipientNewName;
        string transferRecipientSub;
    }

    function test_popfull_end_to_end() public {
        vm.startPrank(ed);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopFull);
        vm.stopPrank();

        // The transfer recipient must be PopFull so the reach fee on this PopFull-tier
        // base name is zero; this end-to-end exercises the lifecycle, not the fee path.
        _grantPopFull(tiago);

        _flowEndToEnd(
            FlowParams({
                nameOwner: ed,
                name: NAME_POPFULL,
                reserved: true,
                selfSub: "app",
                otherSub: "blog",
                otherOwner: leonardo,
                transferTo: tiago,
                transferRecipientNewName: "transfername01",
                transferRecipientSub: "docs"
            })
        );
    }

    function test_poplite_end_to_end() public {
        vm.startPrank(leonardo);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopLite);
        vm.stopPrank();

        // The cross-tier fee gate now requires the recipient to be on a tier
        // that prices the post-transfer name at zero. PopFull is the smallest
        // such tier that also satisfies the recipient's later NoStatus-classified
        // registration in `_flowEndToEnd`.
        _grantPopFull(tiago);

        _flowEndToEnd(
            FlowParams({
                nameOwner: leonardo,
                name: NAME_POPLITE,
                reserved: true,
                selfSub: "app",
                otherSub: "blog",
                otherOwner: ed,
                transferTo: tiago,
                transferRecipientNewName: "transfername01",
                transferRecipientSub: "docs"
            })
        );
    }

    function test_nostatus_end_to_end() public {
        _flowEndToEnd(
            FlowParams({
                nameOwner: tiago,
                name: NAME_NOSTATUS,
                reserved: false,
                selfSub: "app",
                otherSub: "blog",
                otherOwner: ed,
                transferTo: leonardo,
                transferRecipientNewName: "transfername01",
                transferRecipientSub: "docs"
            })
        );
    }

    function _flowEndToEnd(FlowParams memory flow) internal {
        uint256 quotedPriceBefore = popRules.priceWithCheck(flow.name, flow.nameOwner).price;

        if (
            popRules.userPopStatus(flow.nameOwner) == IPopRules.PopStatus.PopFull
                || popRules.userPopStatus(flow.nameOwner) == IPopRules.PopStatus.PopLite
        ) {
            assertEq(quotedPriceBefore, 0);
        }

        _commitAndRegister(flow.name, flow.nameOwner, flow.reserved);

        bytes32 labelHash = keccak256(bytes(flow.name));
        bytes32 node = _namehash(dotNode, labelHash);
        uint256 tokenId = uint256(node);

        assertEq(dotnsRegistrar.ownerOf(tokenId), flow.nameOwner);
        assertTrue(dotnsRegistry.recordExists(node));
        assertEq(dotnsRegistry.owner(node), flow.nameOwner);
        assertEq(dotnsRegistry.resolver(node), address(dotnsReverseResolver));

        string memory fullName = string.concat(flow.name, ".dot");

        if (flow.reserved) {
            assertEq(dotnsReverseResolver.nameOf(flow.nameOwner), fullName);
        } else {
            assertEq(dotnsReverseResolver.nameOf(flow.nameOwner), "");
        }

        Store ownerStore = Store(address(storeFactory.getDeployedStore(flow.nameOwner)));
        assertTrue(address(ownerStore) != address(0));

        bytes32 storeKey = _storeKey(labelHash);

        assertEq(ownerStore.getValueFor(flow.nameOwner, storeKey), fullName);
        assertTrue(ownerStore.isLocked(flow.nameOwner, storeKey));
        _assertStoreContainsValue(flow.nameOwner, ownerStore, fullName);

        vm.startPrank(flow.nameOwner);
        dotnsContentResolver.setContenthash(node, CID_A);
        vm.stopPrank();
        assertEq(dotnsContentResolver.contenthash(node), CID_A);

        bytes32 selfSubnode =
            _setSubnode(flow.nameOwner, node, flow.selfSub, flow.name, flow.nameOwner);
        assertEq(dotnsRegistry.owner(selfSubnode), flow.nameOwner);
        _assertStoreContainsValue(flow.nameOwner, ownerStore, _fullSubname(flow.selfSub, flow.name));

        bytes32 otherSubnode =
            _setSubnode(flow.nameOwner, node, flow.otherSub, flow.name, flow.otherOwner);
        assertEq(dotnsRegistry.owner(otherSubnode), flow.otherOwner);

        Store otherOwnerStore = Store(address(storeFactory.getDeployedStore(flow.otherOwner)));
        assertTrue(address(otherOwnerStore) != address(0));
        _assertStoreContainsValue(
            flow.otherOwner, otherOwnerStore, _fullSubname(flow.otherSub, flow.name)
        );

        vm.startPrank(flow.otherOwner);
        dotnsContentResolver.setContenthash(otherSubnode, CID_B);
        vm.stopPrank();
        assertEq(dotnsContentResolver.contenthash(otherSubnode), CID_B);

        vm.startPrank(flow.nameOwner);
        dotnsRegistrar.transferFrom(flow.nameOwner, flow.transferTo, tokenId);
        vm.stopPrank();

        assertEq(dotnsRegistrar.ownerOf(tokenId), flow.transferTo);

        assertEq(dotnsRegistry.owner(node), flow.transferTo);

        if (flow.reserved) {
            assertEq(dotnsReverseResolver.nameOf(flow.nameOwner), "");
        }

        _assertStoreContainsValue(flow.nameOwner, ownerStore, fullName);

        vm.startPrank(flow.transferTo);
        dotnsContentResolver.setContenthash(node, CID_B);
        vm.stopPrank();
        assertEq(dotnsContentResolver.contenthash(node), CID_B);

        uint256 transferRecipientQuotedPrice =
            popRules.priceWithCheck(flow.transferRecipientNewName, flow.transferTo).price;

        if (
            popRules.userPopStatus(flow.transferTo) == IPopRules.PopStatus.PopFull
                || popRules.userPopStatus(flow.transferTo) == IPopRules.PopStatus.PopLite
        ) {
            assertEq(transferRecipientQuotedPrice, 0);
        }

        _commitAndRegister(flow.transferRecipientNewName, flow.transferTo, false);

        bytes32 transferRecipientLabelHash = keccak256(bytes(flow.transferRecipientNewName));
        bytes32 transferRecipientNode = _namehash(dotNode, transferRecipientLabelHash);

        assertTrue(dotnsRegistry.recordExists(transferRecipientNode));
        assertEq(dotnsRegistry.owner(transferRecipientNode), flow.transferTo);

        Store transferRecipientStore =
            Store(address(storeFactory.getDeployedStore(flow.transferTo)));
        assertTrue(address(transferRecipientStore) != address(0));

        string memory transferRecipientFullName =
            string.concat(flow.transferRecipientNewName, ".dot");
        _assertStoreContainsValue(
            flow.transferTo, transferRecipientStore, transferRecipientFullName
        );

        vm.startPrank(flow.transferTo);
        dotnsContentResolver.setContenthash(transferRecipientNode, CID_A);
        vm.stopPrank();
        assertEq(dotnsContentResolver.contenthash(transferRecipientNode), CID_A);

        _setSubnode(
            flow.transferTo,
            transferRecipientNode,
            flow.transferRecipientSub,
            flow.transferRecipientNewName,
            flow.transferTo
        );

        _assertStoreContainsValue(
            flow.transferTo,
            transferRecipientStore,
            _fullSubname(flow.transferRecipientSub, flow.transferRecipientNewName)
        );
    }

    function test_third_party_reserved_registration_preserves_existing_reverse() public {
        address victim = ed;
        address payer = leonardo;

        _commitAndRegister(NAME_NOSTATUS, victim, false);
        assertEq(dotnsReverseResolver.nameOf(victim), "");

        vm.startPrank(victim);
        popRules.setUserPopStatus(IPopRules.PopStatus.PopFull);
        vm.stopPrank();

        string memory victimPrimary = "victimname01";
        _commitAndRegister(victimPrimary, victim, true);
        assertEq(dotnsReverseResolver.nameOf(victim), "victimname01.dot");

        string memory giftedName = "giftedname01";

        bytes32 secret = keccak256(abi.encodePacked(giftedName, victim, block.timestamp, payer));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: giftedName, owner: victim, secret: secret, reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);

        vm.prank(payer);
        dotnsRegistrarController.commit(commitment);

        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        uint256 quotedPrice = popRules.priceWithCheck(giftedName, victim).price;

        vm.prank(payer);
        dotnsRegistrarController.register{value: quotedPrice}(registration);

        bytes32 labelHash = keccak256(bytes(giftedName));
        bytes32 node = _namehash(dotNode, labelHash);

        assertEq(dotnsRegistrar.ownerOf(uint256(node)), victim);
        assertEq(dotnsRegistry.owner(node), victim);
        assertEq(dotnsReverseResolver.nameOf(victim), "victimname01.dot");
    }

    function _setSubnode(
        address parentOwner,
        bytes32 parentNode,
        string memory subLabel,
        string memory parentLabel,
        address subOwner
    )
        internal
        returns (bytes32 subnode)
    {
        IDotnsRegistry.SubnodeRecord memory subnodeRecord = IDotnsRegistry.SubnodeRecord({
            parentNode: parentNode, subLabel: subLabel, parentLabel: parentLabel, owner: subOwner
        });

        vm.startPrank(parentOwner);
        subnode = dotnsRegistry.setSubnodeOwner(subnodeRecord);
        vm.stopPrank();

        bytes32 expectedSubnode = _namehash(parentNode, keccak256(bytes(subLabel)));
        assertEq(subnode, expectedSubnode);

        assertTrue(dotnsRegistry.recordExists(subnode));
        assertEq(dotnsRegistry.resolver(subnode), address(dotnsReverseResolver));
    }

    function _assertStoreContainsValue(
        address user,
        Store store,
        string memory expectedValue
    )
        internal
    {
        vm.startPrank(user);
        string[] memory values = store.getValues();
        vm.stopPrank();
        require(_contains(values, expectedValue), "Store value missing");
    }

    function _fullSubname(
        string memory subLabel,
        string memory parentLabel
    )
        internal
        pure
        returns (string memory)
    {
        return string.concat(string.concat(subLabel, string.concat(".", parentLabel)), ".dot");
    }

    function test_upgrade_ladder_friction_credits_insurance_through_lifecycle() public {
        // End-to-end flow that exercises both new pricing branches:
        //   1) NoStatus sender sponsors a base-name registration for a PopFull owner.
        //      Owner price is zero (verified), but the sender's reach is below PopFull,
        //      so the controller's friction branch fires and credits the NoStatus rate
        //      to the insurance fund. No refundable position is created.
        //   2) The PopFull owner transfers the name to a PopLite recipient. The recipient
        //      is "covered" in price terms (priceForTo is zero) but reaches above their
        //      tier (label is PopFull), so the registrar's reach fee charges the same
        //      length-scaled rate, again to insurance.
        //   3) The PopLite owner transfers the name to a PopFull recipient. PopFull
        //      meets reach for every label tier, so the move is free.
        //
        // The single-tier-price ladder is the design's core pressure: the only
        // friction-free position is PopFull, in every direction.
        // PopFull-tier label, length 13.
        string memory label = "alicelongname";
        bytes32 labelHash = keccak256(bytes(label));
        bytes32 node = _namehash(dotNode, labelHash);
        uint256 tokenId = uint256(node);

        // Sponsor defaults to NoStatus; owner is granted PopFull below.
        address nostatusSponsor = ed;
        address fullOwner = leonardo;
        address liteRecipient = tiago;

        _grantPopFull(fullOwner);

        // Step 1: NoStatus sponsor registers the base name for the PopFull owner.
        bytes32 secret =
            keccak256(abi.encodePacked(label, fullOwner, nostatusSponsor, block.timestamp));
        IDotnsRegistrarController.Registration memory registration =
            IDotnsRegistrarController.Registration({
                label: label, owner: fullOwner, secret: secret, reserved: true
            });

        bytes32 commitment = dotnsRegistrarController.makeCommitment(registration);
        vm.prank(fullOwner);
        dotnsRegistrarController.commit(commitment);
        vm.warp(block.timestamp + dotnsRegistrarController.minCommitmentAge() + 1);

        uint256 friction = popRules.reachFee(label, nostatusSponsor);
        assertGt(friction, 0, "sponsor reaches above tier; friction must be non-zero");
        uint256 insuranceAfterRegistration;
        {
            uint256 insuranceBefore = dotnsNameEscrow.insuranceFund();
            vm.prank(nostatusSponsor);
            dotnsRegistrarController.register{value: friction}(registration);
            insuranceAfterRegistration = dotnsNameEscrow.insuranceFund();
            assertEq(
                insuranceAfterRegistration - insuranceBefore, friction, "friction credits insurance"
            );
        }
        assertEq(dotnsRegistrar.ownerOf(tokenId), fullOwner, "name minted to verified owner");

        // Step 2: Transfer to a PopLite recipient. Reach fee charges, runningMax stays
        // unchanged because no tier delta was actually paid.
        _grantPopLite(liteRecipient);

        uint256 reachFee = dotnsRegistrar.quoteTransferFee(tokenId, liteRecipient);
        assertGt(reachFee, 0, "lite recipient owes the reach fee on a base name");

        uint256 runningMaxBeforeTransfer = dotnsNameEscrow.runningMax(tokenId);
        vm.prank(fullOwner);
        dotnsRegistrar.transferFrom{value: reachFee}(fullOwner, liteRecipient, tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), liteRecipient);
        assertEq(
            dotnsNameEscrow.insuranceFund() - insuranceAfterRegistration,
            reachFee,
            "reach fee credits insurance"
        );
        assertEq(
            dotnsNameEscrow.runningMax(tokenId),
            reachFee,
            "runningMax tracks the highest payment through escrow"
        );

        // Step 3: Transfer to a PopFull recipient. PopFull meets reach for every label
        // tier, so the move is free.
        address fullRecipient = makeAddr("fullRecipient");
        _grantPopFull(fullRecipient);

        assertEq(
            dotnsRegistrar.quoteTransferFee(tokenId, fullRecipient),
            0,
            "popfull recipient pays no friction"
        );
        uint256 insuranceBeforeFinalMove = dotnsNameEscrow.insuranceFund();

        vm.prank(liteRecipient);
        dotnsRegistrar.transferFrom(liteRecipient, fullRecipient, tokenId);

        assertEq(dotnsRegistrar.ownerOf(tokenId), fullRecipient);
        assertEq(
            dotnsNameEscrow.insuranceFund(),
            insuranceBeforeFinalMove,
            "free transfer must not credit insurance"
        );
    }
}
