// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {BaseDotns} from "../../base/BaseDotns.t.sol";
import {ReservedGrantHandler} from "./ReservedGrantHandler.t.sol";

/// @title Dotns Reserved Grant Invariant Suite
/// @notice Asserts the properties the grant-gated reserved path exists to provide, across any
///         reachable interleaving of grants, relayed mints, ungranted attempts and double spends:
///         only granted labels mint, they mint to the beneficiary rather than the submitter, a
///         grant is spent exactly once, and no reserved mint ever writes a reverse record.
contract DotnsRegistrarReservedGrantInvariantTest is BaseDotns {
    ReservedGrantHandler public handler;

    function setUp() public override {
        super.setUp();

        handler = new ReservedGrantHandler(
            dotnsRegistrarController,
            dotnsNameWhitelist,
            dotnsRegistrar,
            dotnsReverseResolver,
            popRules
        );

        handler.addActor(ed);
        handler.addActor(leonardo);
        handler.addActor(tiago);
        // Seed one grant so `mintGranted` has a target from the very first call.
        handler.grantName(0);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.grantName.selector;
        selectors[1] = handler.mintGranted.selector;
        selectors[2] = handler.attemptUngranted.selector;
        selectors[3] = handler.attemptDoubleSpend.selector;
        selectors[4] = handler.attemptGrantOwnerMismatch.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        excludeContract(address(dotnsRegistrarController));
        excludeContract(address(dotnsNameWhitelist));
        excludeContract(address(dotnsRegistrar));
        excludeContract(address(dotnsRegistry));
        excludeContract(address(dotnsReverseResolver));
        excludeContract(address(dotnsNameEscrow));
        excludeContract(address(protocolRegistry));
        excludeContract(address(storeFactory));
        excludeContract(address(popRules));
    }

    /// @notice The campaign must actually grant, mint and attempt, otherwise the gate invariants
    /// below would hold vacuously over an empty set. Coverage cannot be an `invariant_` function:
    /// those are also evaluated once before the first action, where every counter is still zero.
    /// `afterInvariant` runs at the end of each run, once the sequence has been played out.
    function afterInvariant() public view {
        assertGt(handler.grantCount(), 0, "no grant was ever issued");
        assertGt(handler.mintCount(), 0, "no grant was ever minted");
        assertGt(handler.ungrantedAttemptCount(), 0, "the ungranted path was never exercised");
    }

    /// @notice A reserved mint without a grant naming its owner must never succeed. Fixture
    /// independent: it trips on a wrongful success whatever else the sequence did.
    function invariant_no_ungranted_mint_succeeds() public view {
        assertFalse(handler.sawUngrantedMint(), "a reserved mint succeeded with no grant");
    }

    /// @notice A grant is single use. Re-minting a spent grant must never succeed.
    function invariant_no_grant_is_spent_twice() public view {
        assertFalse(handler.sawDoubleSpend(), "a spent grant minted a second time");
    }

    /// @notice Every mint spends its grant. Asserted from the grant itself rather than from a
    /// later failure: the grant check runs before the availability check, so a grant left live
    /// would show up as `NameNotAvailable` and look identical to a correctly spent one.
    function invariant_every_mint_spends_its_grant() public view {
        assertFalse(handler.sawGrantSurviveMint(), "a grant outlived the mint that spent it");
    }

    /// @notice The gate pairs label with owner. A live grant for one address must never admit a
    /// registration for another.
    function invariant_a_grant_admits_only_its_beneficiary() public view {
        assertFalse(handler.sawGrantOwnerMismatch(), "a grant admitted the wrong beneficiary");
    }

    /// @notice The gate reads `registration.owner`, so a relayed mint lands on the beneficiary.
    /// The name must never end up with the submitter.
    function invariant_minted_names_belong_to_their_beneficiary() public view {
        assertFalse(handler.sawWrongOwner(), "a reserved mint landed on the wrong address");

        string[] memory labels = handler.mintedLabelsList();
        for (uint256 i = 0; i < labels.length; i++) {
            assertEq(
                dotnsRegistrar.ownerOf(handler.tokenIdOf(labels[i])),
                handler.mintedTo(labels[i]),
                "minted name drifted from its beneficiary"
            );
        }
    }

    /// @notice Every grant is either still pending or has minted exactly one name.
    function invariant_grants_are_pending_or_minted_never_both() public view {
        assertEq(
            handler.grantCount(),
            handler.pendingLabelCount() + handler.mintedLabelsList().length,
            "a grant is neither pending nor minted"
        );
    }

    /// @notice No reserved mint writes a reverse record. Beneficiaries here receive names only
    /// through the reserved path, so their reverse record must stay empty for the whole campaign.
    function invariant_reserved_path_never_writes_a_reverse_record() public view {
        address[] memory accounts = handler.beneficiaryList();
        for (uint256 i = 0; i < accounts.length; i++) {
            assertEq(
                dotnsReverseResolver.nameOf(accounts[i]), "", "reserved mint wrote a reverse record"
            );
        }
    }
}
