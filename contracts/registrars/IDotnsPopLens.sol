// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IPopRules} from "../pop/IPopRules.sol";

/// @title IDotnsPopLens
/// @notice Read-only view over PoP identity data, composed from the controller, the registrar,
/// the store factory, the PoP resolver, and PopRules.
/// @dev Holds no state of its own beyond the protocol registry it resolves siblings through, and
/// takes no part in issuance. It exists so the query surface lives outside the controller, which
/// keeps the controller within the contract-size limit and keeps ownership on the registrar.
/// @custom:security-contact admin@parity.io
interface IDotnsPopLens {
    /// @notice One row in a per-account name listing: the name and the node used to look it up.
    /// @dev Computed on read; not stored. `settled` is false while the name still sits in the
    /// temporary pending-claim queue and true once its label is written into a `LabelStore`.
    /// `deadline` is the pending settlement deadline (`mintedAt + reservationDuration`) and is
    /// zero for a settled name.
    /// @param node namehash of the name; the key for chat-key, link, and detail lookups.
    /// @param label Full name string.
    /// @param settled Whether the label is written into a `LabelStore`.
    /// @param deadline Pending settlement deadline, or zero when settled.
    struct Name {
        bytes32 node;
        string label;
        bool settled;
        uint64 deadline;
    }

    /// @notice The full on-chain record for a single name, gathered from the registrar, the PoP
    /// resolver, and PopRules in one read.
    /// @dev Computed on read; not stored. Never reverts on an unminted or unsettled name: absent
    /// fields read as zero or empty. `tier` classifies the label shape (the tier the name
    /// requires), not the owner's personhood. `fullClaim` is keyed by the lite labelhash, which
    /// cannot be recovered from a node alone, so it is populated by @custom:function nameDetail
    /// and left zero by @custom:function nameDetailByNode unless the label is independently
    /// resolvable.
    /// @param node namehash of the name.
    /// @param label Full name string, or empty when the name is unminted or its claim is unsettled.
    /// @param owner Current registrar owner, or the zero address when the name does not exist.
    /// @param exists Whether the name is minted.
    /// @param settled Whether the label is written into the current owner's `LabelStore`.
    /// @param tier PopRules classification of the label.
    /// @param chatKey Chat-key bytes recorded on the PoP resolver for the node.
    /// @param liteLink For a full name, the linked lite labelhash; zero otherwise.
    /// @param fullClaim For a lite name, the promoted full node; zero otherwise or when
    /// unresolvable from a node.
    struct NameDetail {
        bytes32 node;
        string label;
        address owner;
        bool exists;
        bool settled;
        IPopRules.PopStatus tier;
        bytes chatKey;
        bytes32 liteLink;
        bytes32 fullClaim;
    }

    /// @notice An account-level summary of PoP state, gathered in one read.
    /// @dev Computed on read; not stored, and never reverts. Name counts are excluded because
    /// counting scans the account's holdings; read them with @custom:function liteNameCountOf and
    /// @custom:function fullNameCountOf when required. The account's personhood tier is read
    /// separately via @custom:function IPopRules.personhoodOf, which consults the personhood
    /// precompile and so does not belong in this precompile-free summary.
    /// @param hasLabelStore Whether the account has a deployed `LabelStore`.
    /// @param pendingClaimCount Number of claims still staged in the pending queue.
    /// @param reservationLabelhash The base label the account holds a live reservation on, or
    /// zero when none.
    struct PopProfile {
        bool hasLabelStore;
        uint256 pendingClaimCount;
        bytes32 reservationLabelhash;
    }

    /// @notice The protocol registry the lens resolves siblings through.
    /// @return registry The protocol registry address.
    function protocolRegistry() external view returns (address registry);

    /// @notice Lists the lite-person names currently owned by `user`.
    /// @dev Reads the user's `LabelStore` labels and pending claims, keeps the gateway-issued
    /// ones carrying a separator, and re-checks each against `registrar.ownerOf` so a name
    /// transferred away
    /// drops out and a name transferred in shows under its current owner. Ordering follows the
    /// store then the pending queue. An `offset` past the end returns an empty array rather than
    /// reverting, and a short return means the slice ended. A gateway name transferred before it
    /// settles has its label in no store, so it cannot appear here and is reachable only by node
    /// via @custom:function nameDetailByNode. Gas grows with the account's holdings, so call it
    /// off-chain. A page holds at most `DotnsConstants.MAX_PAGE_SIZE` entries, and the pending
    /// portion covers up to that many staged claims.
    /// A name is listed only when @custom:function IDotnsPopController.isPopIssued confirms the
    /// gateway minted it, so a name that merely resembles a lite label is not listed: neither a
    /// public registration spelled `joseph42` nor a subname stored as `joseph.42`. Among issued
    /// names the separator is what marks a lite one, since provenance covers full-person names
    /// too. Identities minted before provenance was recorded have none to confirm, so they are
    /// not listed and are re-issued through the gateway.
    /// @param user Account whose lite names are listed.
    /// @param offset Start index into the filtered sequence.
    /// @param limit Maximum entries to return.
    /// @return names Page of the account's lite names; see @custom:struct Name.
    function liteNamesOf(
        address user,
        uint256 offset,
        uint256 limit
    )
        external
        view
        returns (Name[] memory names);

    /// @notice Lists the full-person names currently owned by `user`.
    /// @dev Same ownership-verified read as @custom:function liteNamesOf, and the same
    /// provenance requirement: a name is listed only when the gateway minted it. It keeps the
    /// labels without a separator, which is the form the gateway issues a full-person name in.
    /// A public registration is not an identity and appears in neither listing, so the two
    /// together cover what the gateway issued rather than everything the account holds.
    /// @param user Account whose full names are listed.
    /// @param offset Start index into the filtered sequence.
    /// @param limit Maximum entries to return.
    /// @return names Page of the account's full names; see @custom:struct Name.
    function fullNamesOf(
        address user,
        uint256 offset,
        uint256 limit
    )
        external
        view
        returns (Name[] memory names);

    /// @notice Counts the lite-person names currently owned by `user`.
    /// @dev Uses the same ownership-verified read as @custom:function liteNamesOf; counting scans
    /// the account's holdings, so gas grows with them. Call it off-chain.
    /// @param user Account whose lite names are counted.
    /// @return count Number of lite names currently owned.
    function liteNameCountOf(address user) external view returns (uint256 count);

    /// @notice Counts the full-person names currently owned by `user`.
    /// @dev Uses the same ownership-verified read as @custom:function fullNamesOf; counting scans
    /// the account's holdings, so gas grows with them. Call it off-chain.
    /// @param user Account whose full names are counted.
    /// @return count Number of full names currently owned.
    function fullNameCountOf(address user) external view returns (uint256 count);

    /// @notice Returns the full on-chain record for a name given its label string.
    /// @dev Resolves the node internally, so a caller holding only the string needs no namehash
    /// implementation. Never reverts on an unknown name: absent fields read as zero or empty.
    /// This overload can populate `fullClaim` because it holds the label and so its labelhash.
    /// @param name Bare label without the TLD. A lite label carries its separator and resolves
    /// here too, since the node is the hash of the whole string.
    /// @return detail The name's record; see @custom:struct NameDetail.
    function nameDetail(string calldata name) external view returns (NameDetail memory detail);

    /// @notice Returns the full on-chain record for a name given its node.
    /// @dev The node cannot be inverted to its labelhash, so `fullClaim` is populated only when
    /// the label is independently resolvable from the node and reads zero otherwise; every other
    /// field is resolved directly. Never reverts on an unknown node.
    /// @param node namehash of the name.
    /// @return detail The name's record; see @custom:struct NameDetail.
    function nameDetailByNode(bytes32 node) external view returns (NameDetail memory detail);

    /// @notice Returns an account-level summary of a user's PoP state.
    /// @dev O(1) facts only; lite and full name counts are read separately via
    /// @custom:function liteNameCountOf and @custom:function fullNameCountOf because those scan
    /// the account's holdings. Never reverts.
    /// @param user Account being summarised.
    /// @return profile The account summary; see @custom:struct PopProfile.
    function profileOf(address user) external view returns (PopProfile memory profile);
}
