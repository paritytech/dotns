// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {IStore} from "../../../contracts/store/IStore.sol";
import {Store} from "../../../contracts/store/Store.sol";

contract StoreTests is BaseDotns {
    function test_setvalue_stores_and_emits() public {
        Store storeInstance;
        vm.prank(owner);
        storeInstance = new Store();

        bytes32 key = keccak256(bytes("ipfs"));
        string memory value = "bafybeigdyrzt";

        vm.expectEmit(true, true, false, true);
        emit IStore.ValueStored(ed, key, value);

        vm.prank(ed);
        storeInstance.setValue(key, value);

        vm.prank(ed);
        assertEq(storeInstance.getValue(key), value);

        vm.prank(ed);
        assertTrue(storeInstance.hasValue(key));

        vm.prank(ed);
        string[] memory allValues = storeInstance.getValues();
        assertEq(allValues.length, 1);
        assertEq(allValues[0], value);
    }

    function test_deletevalue_clears_and_emits() public {
        Store storeInstance;
        vm.prank(owner);
        storeInstance = new Store();

        bytes32 key = keccak256(bytes("ipfs"));
        string memory value = "bafybeigdyrzt";

        vm.prank(ed);
        storeInstance.setValue(key, value);

        vm.expectEmit(true, true, false, true);
        emit IStore.ValueDeleted(ed, key);

        vm.prank(ed);
        storeInstance.deleteValue(key);

        vm.prank(ed);
        assertFalse(storeInstance.hasValue(key));

        vm.prank(ed);
        assertEq(bytes(storeInstance.getValue(key)).length, 0);

        vm.prank(ed);
        string[] memory allValues = storeInstance.getValues();
        assertEq(allValues.length, 1);
        assertEq(allValues[0], value);
    }

    function test_setvaluefor_authorized_store_writes_for_user() public {
        Store storeInstance;
        vm.prank(owner);
        storeInstance = new Store();

        bytes32 key = keccak256(bytes("ipfs"));
        string memory value = "bafybeigdyrzt";

        vm.prank(owner);
        storeInstance.authorizeStore(leonardo);

        vm.expectEmit(true, true, false, true);
        emit IStore.ValueStored(ed, key, value);

        vm.prank(leonardo);
        storeInstance.setValueFor(ed, key, value);

        assertEq(storeInstance.getValueFor(ed, key), value);
        assertTrue(storeInstance.isAuthorized(leonardo));
    }

    function test_dotnscontroller_bypasses_authorized_store_list() public {
        Store storeInstance;
        vm.prank(owner);
        storeInstance = new Store();

        bytes32 key = keccak256(bytes("ipfs"));
        string memory value = "bafybeigdyrzt";

        vm.prank(owner);
        storeInstance.authorizeDotnsController(leonardo);

        vm.prank(leonardo);
        storeInstance.setValueFor(ed, key, value);

        assertEq(storeInstance.getValueFor(ed, key), value);
        assertTrue(storeInstance.isDotnsController(leonardo));
    }

    function test_setvaluefor_by_dotnscontroller_locks_key() public {
        Store storeInstance;
        vm.prank(owner);
        storeInstance = new Store();

        bytes32 key = keccak256(bytes("ipfs"));
        string memory value = "bafybeigdyrzt";

        vm.prank(owner);
        storeInstance.authorizeDotnsController(leonardo);

        vm.expectEmit(true, true, true, true);
        emit IStore.KeyLockedPermanently(ed, key, leonardo);

        vm.prank(leonardo);
        storeInstance.setValueFor(ed, key, value);

        assertTrue(storeInstance.isLocked(ed, key));

        vm.expectRevert(abi.encodeWithSelector(IStore.KeyLocked.selector, ed, key));
        vm.prank(ed);
        storeInstance.setValue(key, "other");

        vm.expectRevert(abi.encodeWithSelector(IStore.KeyLocked.selector, ed, key));
        vm.prank(ed);
        storeInstance.deleteValue(key);
    }

    function test_setvaluefor_reverts_when_not_authorized() public {
        Store storeInstance;
        vm.prank(owner);
        storeInstance = new Store();

        bytes32 key = keccak256(bytes("ipfs"));

        vm.expectRevert(abi.encodeWithSelector(IStore.NotAuthorised.selector, leonardo));
        vm.prank(leonardo);
        storeInstance.setValueFor(ed, key, "bafy");
    }

    function test_unauthorize_store_blocks_setvaluefor() public {
        Store storeInstance;
        vm.prank(owner);
        storeInstance = new Store();

        bytes32 key = keccak256(bytes("ipfs"));

        vm.prank(owner);
        storeInstance.authorizeStore(leonardo);

        vm.prank(owner);
        storeInstance.unauthorizeStore(leonardo);

        vm.expectRevert(abi.encodeWithSelector(IStore.NotAuthorised.selector, leonardo));
        vm.prank(leonardo);
        storeInstance.setValueFor(ed, key, "bafy");
    }

    function test_values_appends_on_overwrite_and_survives_delete() public {
        Store storeInstance;
        vm.prank(owner);
        storeInstance = new Store();

        bytes32 key = keccak256(bytes("ipfs"));
        string memory v1 = "bafy1";
        string memory v2 = "bafy2";

        vm.startPrank(ed);
        storeInstance.setValue(key, v1);
        storeInstance.setValue(key, v2);
        storeInstance.deleteValue(key);
        vm.stopPrank();

        vm.prank(ed);
        string[] memory allValues = storeInstance.getValues();
        assertEq(allValues.length, 2);
        assertEq(allValues[0], v1);
        assertEq(allValues[1], v2);

        vm.prank(ed);
        assertEq(bytes(storeInstance.getValue(key)).length, 0);
    }
}
