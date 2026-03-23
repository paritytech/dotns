// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {Store, IStore} from "../../../contracts/store/Store.sol";

contract StoreTests is BaseDotns {
    function test_setvalue_stores_and_emits() public {
        vm.startPrank(owner);
        Store storeInstance = new Store();
        vm.stopPrank();

        bytes32 key = keccak256(bytes("ipfs"));
        string memory value = "bafybeigdyrzt";

        vm.expectEmit(true, true, false, true);
        emit IStore.ValueStored(ed, key, value);

        vm.startPrank(ed);
        storeInstance.setValue(key, value);

        assertEq(storeInstance.getValue(key), value);
        assertTrue(storeInstance.hasValue(key));

        string[] memory allValues = storeInstance.getValues();
        vm.stopPrank();

        assertEq(allValues.length, 1);
        assertEq(allValues[0], value);
    }

    function test_deletevalue_clears_and_emits() public {
        vm.startPrank(owner);
        Store storeInstance = new Store();
        vm.stopPrank();

        bytes32 key = keccak256(bytes("ipfs"));
        string memory value = "bafybeigdyrzt";

        vm.startPrank(ed);
        storeInstance.setValue(key, value);

        vm.expectEmit(true, true, false, true);
        emit IStore.ValueDeleted(ed, key);

        storeInstance.deleteValue(key);

        assertFalse(storeInstance.hasValue(key));
        assertEq(bytes(storeInstance.getValue(key)).length, 0);

        string[] memory allValues = storeInstance.getValues();
        vm.stopPrank();

        assertEq(allValues.length, 1);
        assertEq(allValues[0], value);
    }

    function test_setvaluefor_authorized_store_writes_for_user() public {
        vm.startPrank(owner);
        Store storeInstance = new Store();
        storeInstance.authorizeStore(leonardo);
        vm.stopPrank();

        bytes32 key = keccak256(bytes("ipfs"));
        string memory value = "bafybeigdyrzt";

        vm.expectEmit(true, true, false, true);
        emit IStore.ValueStored(ed, key, value);

        vm.startPrank(leonardo);
        storeInstance.setValueFor(ed, key, value);
        vm.stopPrank();

        assertEq(storeInstance.getValueFor(ed, key), value);
        assertTrue(storeInstance.isAuthorized(leonardo));
    }

    function test_setvaluefor_by_dotnscontroller_locks_key() public {
        vm.startPrank(owner);
        Store storeInstance = new Store();
        storeInstance.authorizeDotnsController(leonardo);
        vm.stopPrank();

        bytes32 key = keccak256(bytes("ipfs"));
        string memory value = "bafybeigdyrzt";

        vm.expectEmit(true, true, true, true);
        emit IStore.KeyLockedPermanently(ed, key, leonardo);

        vm.startPrank(leonardo);
        storeInstance.setValueFor(ed, key, value);
        vm.stopPrank();

        assertEq(storeInstance.getValueFor(ed, key), value);
        assertTrue(storeInstance.isDotnsController(leonardo));
        assertTrue(storeInstance.isLocked(ed, key));

        vm.startPrank(ed);
        vm.expectRevert(abi.encodeWithSelector(IStore.KeyLocked.selector, ed, key));
        storeInstance.setValue(key, "other");

        vm.expectRevert(abi.encodeWithSelector(IStore.KeyLocked.selector, ed, key));
        storeInstance.deleteValue(key);
        vm.stopPrank();
    }

    function test_setvaluefor_reverts_when_not_authorized() public {
        vm.startPrank(owner);
        Store storeInstance = new Store();
        vm.stopPrank();

        bytes32 key = keccak256(bytes("ipfs"));

        vm.expectRevert(abi.encodeWithSelector(IStore.NotAuthorised.selector, leonardo));
        vm.startPrank(leonardo);
        storeInstance.setValueFor(ed, key, "bafy");
        vm.stopPrank();
    }

    function test_unauthorize_store_blocks_setvaluefor() public {
        vm.startPrank(owner);
        Store storeInstance = new Store();
        storeInstance.authorizeStore(leonardo);
        storeInstance.unauthorizeStore(leonardo);
        vm.stopPrank();

        bytes32 key = keccak256(bytes("ipfs"));

        vm.expectRevert(abi.encodeWithSelector(IStore.NotAuthorised.selector, leonardo));
        vm.startPrank(leonardo);
        storeInstance.setValueFor(ed, key, "bafy");
        vm.stopPrank();
    }

    function test_values_appends_on_overwrite_and_survives_delete() public {
        vm.startPrank(owner);
        Store storeInstance = new Store();
        vm.stopPrank();

        bytes32 key = keccak256(bytes("ipfs"));
        string memory v1 = "bafy1";
        string memory v2 = "bafy2";

        vm.startPrank(ed);
        storeInstance.setValue(key, v1);
        storeInstance.setValue(key, v2);
        storeInstance.deleteValue(key);

        string[] memory allValues = storeInstance.getValues();
        bytes memory current = bytes(storeInstance.getValue(key));
        vm.stopPrank();

        assertEq(allValues.length, 2);
        assertEq(allValues[0], v1);
        assertEq(allValues[1], v2);
        assertEq(current.length, 0);
    }
}
