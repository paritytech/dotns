// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../base/BaseDotns.t.sol";
import {IDotnsPopController} from "../../contracts/registrars/IDotnsPopController.sol";
import {IPopRules} from "../../contracts/pop/IPopRules.sol";
import {ILabelStore} from "../../contracts/store/ILabelStore.sol";
import {IUserStore} from "../../contracts/store/IUserStore.sol";
import {LabelStore} from "../../contracts/store/LabelStore.sol";
import {UserStore} from "../../contracts/store/UserStore.sol";

/// @title LabelStoreV2Int
/// @notice Test-only LabelStore implementation that exposes a marker for verifying
///         beacon upgrades.
contract LabelStoreV2Int is LabelStore {
    /// @notice Returns a sentinel string proving the V2 implementation is active.
    function marker() external pure returns (string memory value) {
        value = "label-v2";
    }
}

/// @title UserStoreV2Int
/// @notice Test-only UserStore implementation that exposes a marker for verifying
///         beacon upgrades.
contract UserStoreV2Int is UserStore {
    /// @notice Returns a sentinel string proving the V2 implementation is active.
    function marker() external pure returns (string memory value) {
        value = "user-v2";
    }
}

/// @title StoreIntegrationTest
/// @notice Integration coverage spanning StoreFactory, LabelStore, UserStore, and
///         the registrar transfer-sync path.
contract StoreIntegrationTest is BaseDotns {
    function test_main_controller_registration_writes_label_store() public {
        string memory label = "alicelives01";
        _register(label, ed, IPopRules.PopStatus.NoStatus);

        address storeAddr = storeFactory.getLabelStore(ed);
        assertTrue(storeAddr != address(0));

        bytes32 node = _namehash(dotNode, keccak256(bytes(label)));
        ILabelStore store = ILabelStore(storeAddr);
        assertEq(store.owner(), ed);
        assertTrue(store.hasLabel(node));
        assertTrue(store.isLocked(node));
        assertEq(store.getLabel(node), "alicelives01.dot");
        assertEq(store.getLabelCount(), 1);
        assertEq(store.getLabelAt(0), "alicelives01.dot");
    }

    function test_pop_controller_registration_writes_label_store() public {
        _grantPopFull(ed);

        string memory base = BASE_LABEL_A;
        // DotnsPopResolver.setChatKey requires exactly 65 bytes (uncompressed ECDSA pubkey).
        bytes memory chatKey = new bytes(65);
        for (uint256 i; i < 65; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            chatKey[i] = bytes1(uint8(i + 1));
        }

        _rootRegisterBaseName(
            IDotnsPopController.FullRegistration({label: base, user: ed, link: _linkFresh(chatKey)})
        );

        vm.prank(ed);
        dotnsPopController.settlePendingClaims(ed, type(uint256).max);

        address storeAddr = storeFactory.getLabelStore(ed);
        assertTrue(storeAddr != address(0));

        bytes32 node = _namehash(dotNode, keccak256(bytes(base)));
        ILabelStore store = ILabelStore(storeAddr);
        assertEq(store.owner(), ed);
        assertTrue(store.hasLabel(node));
        assertEq(store.getLabel(node), string.concat(base, ".dot"));
    }

    function test_erc721_transfer_syncs_label_to_recipient_store() public {
        string memory label = "transferred01";
        bytes32 node = _register(label, ed, IPopRules.PopStatus.NoStatus);
        uint256 tokenId = uint256(node);

        uint256 outboundFee = dotnsRegistrar.quoteTransferFee(tokenId, leonardo);
        vm.prank(ed);
        dotnsRegistrar.transferFrom{value: outboundFee}(ed, leonardo, tokenId);

        address recipientStore = storeFactory.getLabelStore(leonardo);
        assertTrue(recipientStore != address(0));
        assertEq(ILabelStore(recipientStore).getLabel(node), string.concat(label, ".dot"));
        assertTrue(ILabelStore(recipientStore).isLocked(node));
    }

    function test_double_transfer_back_does_not_revert_on_existing_lock() public {
        // Base must be >= 9 chars to classify as NoStatus under PopRules.
        string memory label = NOSTATUS_LABEL_A;
        bytes32 node = _register(label, ed, IPopRules.PopStatus.NoStatus);
        uint256 tokenId = uint256(node);

        uint256 outboundFee = dotnsRegistrar.quoteTransferFee(tokenId, leonardo);
        vm.prank(ed);
        dotnsRegistrar.transferFrom{value: outboundFee}(ed, leonardo, tokenId);
        uint256 returnFee = dotnsRegistrar.quoteTransferFee(tokenId, ed);
        vm.prank(leonardo);
        dotnsRegistrar.transferFrom{value: returnFee}(leonardo, ed, tokenId);

        address edStore = storeFactory.getLabelStore(ed);
        address leonardoStore = storeFactory.getLabelStore(leonardo);
        assertTrue(ILabelStore(edStore).isLocked(node));
        assertTrue(ILabelStore(leonardoStore).isLocked(node));
    }

    function test_user_claim_round_trip_with_history() public {
        vm.prank(ed);
        address userStoreAddr = storeFactory.claimUserStore();
        IUserStore store = IUserStore(userStoreAddr);

        bytes32 cidKey = keccak256("cid.home");

        vm.startPrank(ed);
        store.setValue(cidKey, bytes("Qm-cid-v1"));
        vm.warp(block.timestamp + 1 days);
        store.setValue(cidKey, bytes("Qm-cid-v2"));
        vm.stopPrank();

        assertEq(store.getValue(cidKey), bytes("Qm-cid-v2"));
        assertEq(store.getHistoryCount(cidKey), 1);
        assertEq(store.getHistoryAt(cidKey, 0).value, bytes("Qm-cid-v1"));
    }

    function test_beacon_upgrade_preserves_label_store_state() public {
        string memory label = "preupgrade01";
        _register(label, ed, IPopRules.PopStatus.NoStatus);
        address storeAddr = storeFactory.getLabelStore(ed);
        bytes32 node = _namehash(dotNode, keccak256(bytes(label)));

        LabelStoreV2Int newImplementation = new LabelStoreV2Int();
        vm.prank(owner);
        storeFactory.upgradeLabelStoreImplementation(address(newImplementation));

        assertEq(LabelStoreV2Int(storeAddr).marker(), "label-v2");
        assertEq(ILabelStore(storeAddr).getLabel(node), string.concat(label, ".dot"));
    }

    function test_beacon_upgrade_preserves_user_store_state() public {
        vm.prank(ed);
        address storeAddr = storeFactory.claimUserStore();
        bytes32 key = keccak256("k");
        vm.prank(ed);
        IUserStore(storeAddr).setValue(key, bytes("before-upgrade"));

        UserStoreV2Int newImplementation = new UserStoreV2Int();
        vm.prank(owner);
        storeFactory.upgradeUserStoreImplementation(address(newImplementation));

        assertEq(UserStoreV2Int(storeAddr).marker(), "user-v2");
        assertEq(IUserStore(storeAddr).getValue(key), bytes("before-upgrade"));
    }

    function test_registration_reuses_factory_owner_predeployed_store() public {
        vm.prank(owner);
        address predeployed = storeFactory.deployLabelStoreFor(ed);

        _register("predeploy01", ed, IPopRules.PopStatus.NoStatus);

        assertEq(storeFactory.getLabelStore(ed), predeployed);
        bytes32 node = _namehash(dotNode, keccak256("predeploy01"));
        assertTrue(ILabelStore(predeployed).hasLabel(node));
    }
}
