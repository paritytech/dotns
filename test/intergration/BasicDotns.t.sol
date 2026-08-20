// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../base/BaseDotns.t.sol";
import {IDotnsRegistry} from "../../contracts/registry/IDotnsRegistry.sol";
import {IDotnsRegistrarController} from "../../contracts/registrars/IDotnsRegistrarController.sol";
import {ILabelStore} from "../../contracts/store/ILabelStore.sol";
import {IPersonhood} from "../../contracts/external/personhood/IPersonhood.sol";
import {DotnsConstants} from "../../contracts/utils/DotnsConstants.sol";

/// @title BasicDotnsIntegration
/// @notice End-to-end happy-path integration coverage for registration,
///         records, subnames, and ERC721 transfers across all PoP tiers.
contract BasicDotnsIntegration is BaseDotns {
    /// @notice PopFull-classified label fixture used by the integration flow.
    string internal constant NAME_POPFULL = "waytalls";
    /// @notice PopLite-classified label fixture used by the integration flow.
    string internal constant NAME_POPLITE = "way2tall01";
    /// @notice NoStatus-classified label fixture used by the integration flow.
    string internal constant NAME_NOSTATUS = "kitesurfing01";

    /// @notice Sample CIDv1 content hash used as the first record value.
    bytes internal constant CID_A =
        hex"e30101701220aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    /// @notice Sample CIDv1 content hash used as the second record value.
    bytes internal constant CID_B =
        hex"e30101701220bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    /// @notice Parameter bag describing a single end-to-end registration flow.
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
        _grantPopFull(ed);

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
        _grantPopLite(leonardo);

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

    /// @notice Returns true when the personhood precompile reports `account` at
    ///         tier `Lite` (1) or `Full` (2) under the dotns context.
    /// @dev Reads the precompile mock installed by @custom:contract BaseDotns so the integration
    ///      flow gates pricing assertions on the same tier the controller sees.
    function _personhoodTierIsAtLeastLite(address account) internal view returns (bool) {
        IPersonhood.PersonhoodInfo memory info = IPersonhood(DotnsConstants.PERSONHOOD)
            .personhoodStatus(account, DotnsConstants.PERSONHOOD_CONTEXT);
        return info.status >= 1;
    }

    /// @notice Drives a full end-to-end registration, records, subname, and
    ///         transfer flow under the configuration described by `flow`.
    /// @dev Aggregates the assertions that every PoP-tier-specific test case
    ///      shares so each tier-level test only needs to supply the parameter
    ///      bag.
    function _flowEndToEnd(FlowParams memory flow) internal {
        uint256 quotedPriceBefore = popRules.priceWithCheck(flow.name, flow.nameOwner).price;

        if (_personhoodTierIsAtLeastLite(flow.nameOwner)) {
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

        ILabelStore ownerStore = ILabelStore(storeFactory.getLabelStore(flow.nameOwner));
        assertTrue(address(ownerStore) != address(0));

        assertEq(ownerStore.getLabel(node), fullName);
        assertTrue(ownerStore.isLocked(node));
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

        ILabelStore otherOwnerStore = ILabelStore(storeFactory.getLabelStore(flow.otherOwner));
        assertTrue(address(otherOwnerStore) != address(0));
        _assertStoreContainsValue(
            flow.otherOwner, otherOwnerStore, _fullSubname(flow.otherSub, flow.name)
        );

        vm.startPrank(flow.otherOwner);
        dotnsContentResolver.setContenthash(otherSubnode, CID_B);
        vm.stopPrank();
        assertEq(dotnsContentResolver.contenthash(otherSubnode), CID_B);

        uint256 _xferFee = dotnsRegistrar.quoteTransferFee(tokenId, flow.transferTo);
        vm.startPrank(flow.nameOwner);
        dotnsRegistrar.transferFrom{value: _xferFee}(flow.nameOwner, flow.transferTo, tokenId);
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

        if (_personhoodTierIsAtLeastLite(flow.transferTo)) {
            assertEq(transferRecipientQuotedPrice, 0);
        }

        _commitAndRegister(flow.transferRecipientNewName, flow.transferTo, false);

        bytes32 transferRecipientLabelHash = keccak256(bytes(flow.transferRecipientNewName));
        bytes32 transferRecipientNode = _namehash(dotNode, transferRecipientLabelHash);

        assertTrue(dotnsRegistry.recordExists(transferRecipientNode));
        assertEq(dotnsRegistry.owner(transferRecipientNode), flow.transferTo);

        ILabelStore transferRecipientStore =
            ILabelStore(storeFactory.getLabelStore(flow.transferTo));
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

        _grantPopFull(victim);

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

    /// @notice Creates a subnode under `parentNode` while pranking as `parentOwner`.
    /// @dev Asserts namehash, record existence, and the inherited resolver address
    ///      so callers can focus on the surrounding behaviour under test.
    /// @param parentOwner Account authorised to set the subnode.
    /// @param parentNode Node hash of the parent record.
    /// @param subLabel Subname label (without dot suffix).
    /// @param parentLabel Parent label (without dot suffix).
    /// @param subOwner Account that should own the new subnode.
    /// @return subnode Resulting subnode hash.
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

    /// @notice Asserts that `store` lists `expectedValue` among its labels.
    /// @dev Walks the store by paginating the full label list, mirroring how a
    ///      consumer client would discover entries.
    function _assertStoreContainsValue(
        address user,
        ILabelStore store,
        string memory expectedValue
    )
        internal
    {
        uint256 count = store.getLabelCount();
        string[] memory values = store.getLabels(0, count);
        user;
        require(_contains(values, expectedValue), "Store value missing");
    }

    /// @notice Builds the fully qualified subname string `sub.parent.dot`.
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
}
