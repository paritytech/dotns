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
    ///      `DotnsPopController` to authenticate Root-origin dispatches via
    ///      `ISystem.callerIsRoot()`.
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

    /// @notice Default deploy-time NoStatus rent price passed into
    ///         `PopRules.initialize` as `_startingPrice`.
    /// @dev 10 DOT under revive's 18-decimal Asset Hub convention. Single
    ///      source of truth for deploy scripts and tests so the value cannot
    ///      drift between call sites. Live deployments rotate the runtime
    ///      `startingPrice` on `PopRules` rather than rebuilding consumers
    ///      against a new constant.
    uint256 internal constant RENT_PRICE = 10 ether;

    /// @notice Operational role allowed to manage the public controller whitelist.
    /// @dev Holders can grant or revoke whitelist entries, but cannot upgrade contracts
    ///      or change protocol configuration.
    bytes32 internal constant WHITELIST_OPERATOR_ROLE = keccak256("DOTNS_WHITELIST_OPERATOR_ROLE");

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

    /// @notice Well-known key for the address authorised to invoke the PoP
    ///         controller's gated entrypoints.
    /// @dev Role: substrate Root-origin shim. Resolves to the Root gateway
    ///      dispatcher deployed against the PoP controller. The dispatcher
    ///      verifies Root authority through the revive System precompile in
    ///      its own frame and forwards calldata to the controller via a
    ///      regular message call; the controller authorises against this
    ///      registry key, so rotating the dispatcher is a single write on
    ///      the protocol registry.
    /// forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant POP_GATEWAY = bytes32("popGateway");
}
