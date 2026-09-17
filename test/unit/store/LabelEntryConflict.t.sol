// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {StoreUtils} from "../../../contracts/utils/StoreUtils.sol";
import {IStoreFactory} from "../../../contracts/store/IStoreFactory.sol";
import {ILabelStore} from "../../../contracts/store/ILabelStore.sol";

/// @notice Drives `StoreUtils` as an authorised store writer. Registered under the registrar key
///         by the test so `StoreAuth.isStoreWriter` accepts it.
contract StoreWriter {
    using StoreUtils for IStoreFactory;

    function writeNew(
        IStoreFactory factory,
        address user,
        bytes32 labelhash,
        string memory label
    )
        external
        returns (address)
    {
        return factory.writeNewLabel(user, labelhash, label);
    }
}

/// @title LabelEntryConflictTests
/// @notice Covers the registration path's refusal to honour a label entry it did not write.
/// @dev `storeLabel` is single-write with no delete, so a wrong entry standing at registration
///      time is permanent: the transfer hook reads the label back, strips the TLD, and reverts
///      `InvalidLabel` on an empty result, leaving the name untransferable forever. The
///      registration path must therefore fail loudly rather than skip its own write.
contract LabelEntryConflictTests is BaseDotns {
    StoreWriter private writer;
    IStoreFactory private factory;

    bytes32 private constant NODE = bytes32(uint256(0xBEEF));
    string private constant CANONICAL = "alice.dot";

    function setUp() public override {
        super.setUp();
        writer = new StoreWriter();
        factory = IStoreFactory(address(storeFactory));

        // Authorise the harness the way a protocol component is authorised.
        vm.prank(owner);
        protocolRegistry.set(bytes32("registrar"), address(writer));
    }

    /// @notice A conflicting entry stops the registration instead of being silently adopted.
    function test_registration_rejects_a_conflicting_entry() public {
        writer.writeNew(factory, ed, NODE, "attacker-string");

        address store = factory.getLabelStore(ed);
        vm.expectRevert(
            abi.encodeWithSelector(
                StoreUtils.LabelEntryConflict.selector, store, NODE, "attacker-string"
            )
        );
        writer.writeNew(factory, ed, NODE, CANONICAL);
    }

    /// @notice An entry that already holds the label being written stays a no-op, so a previous
    ///         holder re-registering the same name is not blocked by their own leftover entry.
    function test_registration_tolerates_a_matching_entry() public {
        writer.writeNew(factory, ed, NODE, CANONICAL);
        writer.writeNew(factory, ed, NODE, CANONICAL);

        address store = factory.getLabelStore(ed);
        assertEq(ILabelStore(store).getLabel(NODE), CANONICAL, "the stored label changed");
    }
}
