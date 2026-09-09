// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title DotNS Constants
/// @notice Protocol-level invariants shared across DotNS contracts.
/// @dev Centralises the well-known protocol-registry keys that every contract uses to discover
///      its siblings (registrar, controller, registry, resolvers, etc.). Each key is a
///      role address resolved at call time, so rotating an implementation is a
///      single `set` on the protocol registry without redeploying consumers. The TLD is not a
///      constant here: it is set per network on the protocol registry and read by every consumer.
/// @custom:security-contact admin@parity.io
library DotnsConstants {
    /// @notice Address of revive's System precompile, exposed by every revive runtime
    ///         that opts the precompile in.
    /// @dev Mirrors the upstream `SYSTEM_ADDR` constant in
    ///      `substrate/frame/revive/uapi/sol/ISystem.sol`. Consumed by
    ///      `DotnsPopController` and `DotnsNameWhitelist` to authenticate
    ///      Root-origin dispatches via `ISystem.originIsRoot()`.
    address internal constant REVIVE_SYSTEM = address(0x0900);

    /// @notice Address of the Proof-of-Personhood precompile backed by the
    ///         alias-accounts pallet on Asset Hub.
    /// @dev Consumed by `PopRules` to read each account's personhood tier
    ///      (`None` / `Lite` / `Full`) and the dotns-scoped `contextAlias`.
    address internal constant PERSONHOOD = address(0x000000000000000000000000000000000a010000);

    /// @notice Application identifier passed to @custom:function IPersonhood.personhoodStatus.
    /// @dev Fixed per project so the same person receives a stable, dotns-only
    ///      `contextAlias` and no cross-application linkability is exposed.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant PERSONHOOD_CONTEXT = bytes32("dotns");

    /// @notice Launch deposit passed into the `DotnsFlatPricing` constructor.
    /// @dev 10 DOT under revive's 18-decimal Asset Hub convention. A new amount is a fresh model
    ///      deployment registered under @custom:constant COST_MODEL, so this constant seeds the
    ///      model rather than being read afterwards. Single source of truth for deploy scripts and
    ///      tests so the seed cannot drift between call sites.
    uint256 internal constant BASE_DEPOSIT = 10 ether;

    /// @notice Price floor F passed into the `DotnsScarcityPricing` candidate's constructor.
    /// @dev Below `BASE_DEPOSIT` so that curve falls above nine characters. Seeds the candidate
    ///      constructor; a new floor is a fresh model deployment.
    uint256 internal constant MIN_PRICE = 0.1 ether;

    /// @notice Well-known key for the cost model pricing registrations by base length.
    /// @dev Role: single authority for the wei amount a registration costs. `PopRules` resolves
    ///      it here on every pricing read, so swapping the model is one `set` on the protocol
    ///      registry without redeploying `PopRules` or its consumers.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant COST_MODEL = bytes32("costModel");

    /// @notice Default release cooldown seeded on `DotnsNameEscrow.initialize`.
    /// @dev Single source of truth for deploy scripts and tests so the value cannot drift between
    ///      call sites. Bounded on-chain by `DotnsNameEscrow.MAX_COOLDOWN`. Live deployments rotate
    ///      the runtime value via `updateCooldown` rather than rebuilding consumers.
    uint256 internal constant ESCROW_COOLDOWN = 15 minutes;

    /// @notice Default redeem window seeded on `DotnsNameEscrow.initialize`.
    /// @dev Single source of truth for deploy scripts and tests. Bounded on-chain by
    ///      `DotnsNameEscrow.MAX_REDEEM_WINDOW`. Live deployments rotate the runtime value via
    ///      `updateRedeemWindow`.
    uint256 internal constant ESCROW_REDEEM_WINDOW = 1 days;
    /// @notice Maximum entries a paginated view returns in a single page.
    /// @dev Shared ceiling for paginated reads: a view clamps its returned array to this figure,
    ///      and callers page through larger sets with `offset`.
    uint256 internal constant MAX_PAGE_SIZE = 200;

    /// @notice Default per-name live-claim cap the name whitelist starts with.
    /// @dev Governance retunes it on the whitelist within `WHITELIST_MAX_CLAIMANTS_LIMIT`.
    uint16 internal constant WHITELIST_DEFAULT_MAX_CLAIMANTS = 64;

    /// @notice Default claim-reason byte cap the name whitelist starts with.
    /// @dev Governance retunes it on the whitelist within `WHITELIST_MAX_REASON_LIMIT`.
    uint256 internal constant WHITELIST_DEFAULT_MAX_REASON_BYTES = 256;

    /// @notice Upper bound on the whitelist live-claim cap. Caps the claim clear-loop below the
    ///         block gas limit.
    uint16 internal constant WHITELIST_MAX_CLAIMANTS_LIMIT = 128;

    /// @notice Upper bound on the whitelist reason byte cap.
    uint256 internal constant WHITELIST_MAX_REASON_LIMIT = 256;

    /// @notice Default cap on labels granted in one `grantNames` call.
    /// @dev Governance retunes it on the whitelist within `WHITELIST_MAX_GRANT_BATCH_LIMIT`.
    uint16 internal constant WHITELIST_DEFAULT_MAX_GRANT_BATCH = 100;

    /// @notice Upper bound on the `grantNames` batch cap. Bounds one call below the block gas
    /// limit.
    uint16 internal constant WHITELIST_MAX_GRANT_BATCH_LIMIT = 256;

    /// @notice Well-known key for the ERC721 registrar backing name ownership.
    /// @dev Role: token-of-record for registered names. Mints, burns, and tracks the
    ///      `tokenId => label` mapping consumed by the forward registry on
    ///      transfer.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant REGISTRAR = bytes32("registrar");

    /// @notice Well-known key for the registrar controller orchestrating commit-reveal
    /// registration. @dev Role: commit-reveal entry point for the public registration flow.
    ///      Calls `register` on the registrar after pricing and validation.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant CONTROLLER = bytes32("controller");

    /// @notice Well-known key for the forward registry storing node ownership and resolver.
    /// @dev Role: source of truth for `(node => owner, resolver)`. Read by every
    ///      resolver gate that defers authority to the node owner.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant REGISTRY = bytes32("registry");

    /// @notice Well-known key for the reverse resolver for address-to-name mapping.
    /// @dev Role: stores `address => name` reverse records. Writer is the
    ///      registrar/controller, not the address holder.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant REVERSE_RESOLVER = bytes32("reverseResolver");

    /// @notice Well-known key for the PoP oracle enforcing eligibility and pricing.
    /// @dev Role: arbiter of PoP cross-flow priority and pricing. Consulted by
    ///      both the public commit-reveal controller and the PoP controller.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant POP_RULES = bytes32("popRules");

    /// @notice Well-known key for the factory deploying per-user Store instances.
    /// @dev Role: deploy-on-demand provisioning of user `LabelStore` proxies and
    ///      authorisation gate for protocol writes into them.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant STORE_FACTORY = bytes32("storeFactory");

    /// @notice Well-known key for the forward resolver storing address records.
    /// @dev Role: `node => address` records. Writes gated on node ownership.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant RESOLVER = bytes32("resolver");

    /// @notice Well-known key for the content resolver storing content hashes and text records.
    /// @dev Role: `node => contenthash`/`text` records and ERC721-style operator
    ///      approvals. Writes gated on node ownership or operator approval.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant CONTENT_RESOLVER = bytes32("contentResolver");

    /// @notice Well-known key for the dedicated PoP controller orchestrating lite/full-person
    ///         username issuance on behalf of the PoP gateway.
    /// @dev Kept distinct from `CONTROLLER` (commit-reveal public controller) so the
    ///      two can coexist per `DotnsRegistrar`'s multi-controller affordance.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant POP_CONTROLLER = bytes32("popController");

    /// @notice Well-known key for the PoP resolver holding per-name records produced
    ///         by the PoP username flow (chat keys, lite => full links).
    /// @dev Role: `node => chatKey` and bidirectional `lite <=> full` link index.
    ///      Writer is the `POP_CONTROLLER`, not the node owner.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant POP_RESOLVER = bytes32("popResolver");

    /// @notice Well-known key for the read-only lens over PoP identity data.
    /// @dev Role: off-chain query surface. Composes the account name listings, the per-name
    ///      record, and the account summary from the controller, registrar, store factory, PoP
    ///      resolver, and PopRules. Holds no authority and is consumed by clients, not by other
    ///      contracts.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant POP_LENS = bytes32("popLens");

    /// @notice Well-known key for the name escrow holding refundable deposits and
    ///         driving the release lifecycle for registered names.
    /// @dev Role: custodial vault for registration deposits and the state machine
    ///      that drives the name release lifecycle.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant NAME_ESCROW = bytes32("nameEscrow");

    /// @notice Well-known key for the generic Multicall3 batching helper.
    /// @dev Role: unauthorised arbitrary-target multicall utility used by
    ///      clients and tooling. Target contracts still enforce their own
    ///      permissions and observe Multicall3 as `msg.sender`.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant MULTICALL3 = bytes32("multicall3");

    /// @notice Well-known key for the CREATE3 factory backing the deterministic
    ///         deploy pipeline.
    /// @dev Role: permissionless CREATE3 deployer. The first deploy stage
    ///      bootstraps the factory, records it under this key, and every later
    ///      stage resolves it from here, so deterministic addresses never depend
    ///      on an environment variable.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant CREATE3_FACTORY = bytes32("create3Factory");

    /// @notice Well-known key for the pre-launch name whitelist that binds a label to the
    ///         one address permitted to register it.
    /// @dev Role: authority for label-bound registration grants. The public controller resolves
    ///      it here and reads it on the reserved path, requiring a grant naming the intended owner
    ///      unless the dispatch is Root, and consuming the grant on a successful mint. The PoP
    ///      controller does not consult it.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant NAME_WHITELIST = bytes32("nameWhitelist");
}
