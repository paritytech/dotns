> [!WARNING]
> This open source code is provided for research, experimentation, and developer education only. This code has not been audited, is actively experimental, and may contain bugs, vulnerabilities, or incomplete features. Use at your own risk.

# Dotns

Smart contracts for registering .dot names on Polkadot.

DotNS is a naming system for Polkadot. An account can register a .dot name, receive an ERC721 token that represents ownership of that name, attach records to it (addresses, text, content hashes, chat keys), and create subnames beneath it. Two independent issuance paths coexist on the same underlying registrar: a public commit-reveal path for anyone who wants a name, and a Proof-of-Personhood gateway path that issues lite-person and full-person usernames on behalf of verified users. Every piece of state the protocol surfaces is readable through public view functions on the chain itself, so a client needs only a node and a small set of well-known contract addresses to answer any question about the system.

## Diagrams

### System diagram

![System diagram](./diagrams/system.png)

## Deployment and operations

Current network addresses and deployment notes are listed in [DEPLOYMENTS.md](./DEPLOYMENTS.md).

## Economics

dotNS uses a single tunable constant, written **D** throughout the protocol. D is the starting price used by PopRules and equals ten DOT at launch; governance can adjust it under the same gate as the upgrade authority. D is the only money quantity the protocol charges; everything else is a composition of D with zero.

D plays two distinct roles. As a **deposit** it is the refundable lock a NoStatus user posts to register a NoStatus-tier label; the deposit is bound to the name, not to the depositor, so it travels with the NFT on every transfer and only unlocks when the current holder releases the name back to escrow. Transferring a funded name forfeits the deposit to the new holder, who inherits the locked D and the right to release later. As a **friction** charge it is the non-refundable amount a sender pays on a cross-tier downward or reach-floor transfer. The two flows are economically distinct: the deposit gates a count of names (one D per NoStatus name in existence), the friction gates the rate of tier laundering.

### Registration matrix

The public controller computes the registration charge as the greater of the owner-side price and the payer-to-owner downward friction; it does not add the two together. The single charge becomes a refundable deposit on a direct NoStatus registration and becomes non-refundable reserve funding on a cross-payer registration.

| Owner tier              | Reserved (stem ≤5) | PopFull-tier (stem 6-8, no digits) | PopLite-tier (stem 6-8, two digits) | NoStatus-tier (stem ≥9)     |
| ----------------------- | ------------------ | ---------------------------------- | ----------------------------------- | --------------------------- |
| **NoStatus user**       | rejected           | rejected                           | rejected                            | direct: pays D into deposit |
| **PopLite user**        | rejected           | rejected                           | gateway-only; free                  | free                        |
| **PopFull user**        | rejected           | free                               | gateway-only; free                  | free                        |
| **Whitelisted address** | free               | free                               | free                                | free                        |

Cross-payer registrations pay the greater of the owner-side price and the transfer-floor amount into the reserve. Reserved labels remain forbidden on the cross-payer path because the owner-side gate still rejects them. Whitelist registrations go through the same commit-reveal pipeline as the public path.

### Transfer matrix

The registrar consults PopRules for the transfer floor. A transfer pays D whenever the recipient's tier is strictly below the sender's, or whenever the recipient cannot reach the label's required tier. A stale PopFull-tier name landing with a PopLite holder, for example, can still owe friction even when the holder-to-holder move otherwise looks same-tier. Same-tier and upward transfers between holders of the label's own class are free of friction.

The deposit, when present, is bound to the name and rides with it on every transfer. The escrow position is rebound to the new holder rather than refunded; only releasing the name back to escrow ever unlocks the locked D. Transferring a funded name is therefore a real forfeiture: the sender hands the locked deposit over to the recipient along with the NFT.

| Sender → Recipient              | Friction (to insurance) | Deposit movement                                     |
| ------------------------------- | ----------------------- | ---------------------------------------------------- |
| NoStatus → NoStatus (same tier) | 0                       | Travels with the name; position rebinds to recipient |
| NoStatus → PopLite or PopFull   | 0                       | Travels with the name; position rebinds to recipient |
| PopLite → NoStatus              | D                       | Any inherited deposit travels with the name          |
| PopLite → PopLite (same)        | 0                       | Any inherited deposit stays bound to the name        |
| PopLite → PopFull (upward)      | 0                       | Any inherited deposit stays bound to the name        |
| PopFull → NoStatus              | D                       | Any inherited deposit travels with the name          |
| PopFull → PopLite (downward)    | D                       | Any inherited deposit stays bound to the name        |
| PopFull → PopFull (same)        | 0                       | Any inherited deposit stays bound to the name        |

The friction is constant and additive across downward hops. Every step that crosses a tier boundary downward charges D independently, so routing a name through intermediary tiers never costs less than the equivalent direct transfer. Laundering pays at least as much as the route it tries to avoid. Because the deposit follows the NFT, a NoStatus user cannot recover their D by handing the name to a fresh address and registering again; the only path back to D is releasing the current name into escrow. This binds Sybil cost to one D per live NoStatus name in existence, independent of how often names change hands.

### Refund and cooldown model

The escrow maintains two separate pull-payment ledgers. The split is deliberate: one ledger is for immediate overpayment withdrawals, and the other is for refunds that must wait behind a cooldown.

- **Overpayment ledger.** No cooldown. Used only as the fallback when a direct registration overpayment cannot be returned to the sender inline.
- **Refund ledger.** Every refund has its own cooldown clock. Used for transfer-fee overpayments. Transfers never credit the refund ledger because the position rides with the name.

Only registrations try to return surplus immediately. Every other refund path waits behind a clock. The deposit unlocked by releasing a funded name is credited to the overpayment ledger rather than the refund ledger: the delay comes from the position's own `withdrawAvailableAt` stamp, so once `withdraw` lands the credit is immediately pullable. The cooldown is bounded to minutes and governance can tune it within that band.

Clients can enumerate pending refunds through the escrow's public refund views. Pagination is capped so refund discovery remains bounded.

### Release lifecycle

Releasing a name starts two independent clocks, and the distinction between them is what makes a released name both recoverable and recyclable.

| Clock | Length | What it gates |
|---|---|---|
| `withdrawAvailableAt` | release + `cooldown` (15 minutes at launch, ≤ 1 hour) | When the holder may credit the deposit to themselves via `withdraw` |
| `redeemableUntil` | release + `redeemWindow` (1 day at launch, ≤ 30 days) | When the holder's exclusive claim on the name ends and `reclaim` opens to anyone |

Both are snapshotted at release time, so a governance change never moves the goalposts on a name already in flight. `redeemWindow` is tuned through `updateRedeemWindow` under the same gate as the upgrade authority.

Inside the redeem window the name belongs to its previous holder. They alone may act on it, and `DotnsRegistrar.available` reports **false** so no client advertises the name as free and no registrant burns a commit-reveal cycle on a registration that cannot succeed. Their options are exclusive:

- **`redeem`** returns the NFT and moves no value. The position keeps its recipient, asset and amount, so the deposit stays locked and the name lands back in its exact pre-release state, releasable again later on a fresh pair of clocks. This is the undo for an accidental release.
- **`withdraw`** credits the deposit and forfeits the right to redeem. A holder who has been paid for the name cannot also take it back; otherwise they would hold a NoStatus name that no deposit backs, and the Sybil bound of one D per live NoStatus name would not hold.

Once `redeemableUntil` is reached, `reclaim` is permissionless through the ordinary commit-reveal path, **whether or not the previous holder ever withdrew**. If the position still holds value, reclaim settles it: the amount is credited to the previous holder's pull-payment balance and stays claimable through `claimWithdrawal` with no deadline. The value follows the departing holder; the name does not wait for them.

That last point is the whole reason the window exists. Reclaim used to require the previous holder to have withdrawn first, which meant a holder who released a name and never came back removed the label from circulation permanently. For the zero-amount positions seeded by free PopFull and PopLite registrations there is nothing to withdraw, so never withdrawing was the default rather than the exception. Bounding the wait with a clock replaces a dependency on someone else's action with one that elapses on its own.

Clients wanting the exact moment a released name becomes registrable should read `redeemableUntil` from `getReleasePosition` rather than polling `available`.

## Contracts

Two controllers sit on top of a single registrar and a single protocol registry. The registrar holds the ERC721 token per name; the registry holds the forward node => (owner, resolver) mapping and subname hierarchy; the resolvers hold per-name records; the protocol registry is the indirection layer through which every contract resolves its siblings at runtime. Controllers are the entry points: they mint names and drive the side effects. Neither controller imports the other. The layers underneath arbitrate collision handling: ERC721 uniqueness on the registrar, and a single reservation table on PopRules that both flows read through.

### DotnsRegistrarController

Commit-reveal controller for the public registration path. A caller first submits a commitment hash, waits out the minimum commitment age, then reveals the registration parameters alongside the payment. The controller validates the commitment, routes price and eligibility through PopRules, and orchestrates every side effect of a successful registration: the mint on the registrar, the forward wire-up on the registry, the reverse record on the reverse resolver, the immutable Store write, and any refund owed on overpayment. Acceptable input is a single DNS label of at least the minimum-length policy; shorter labels revert with `LabelTooShort`. Labels classified as governance-reserved revert with `GovernanceReserved`; a base stem held by another user reverts with `NameReserved`. On the cross-payer path the owner's recorded PoP tier must meet the label's required tier — verified-payer-for-unverified-owner sponsorship is rejected with `OwnerStatusInsufficient`, so the direct-path personhood guarantee carries over to sponsored registrations.

### DotnsPopController

Dedicated controller for the Proof-of-Personhood gateway flow. Lives behind its own UUPS proxy with its own storage and is registered on the registrar via addController alongside the commit-reveal controller. Its gated entry points are callable only from the address resolved through the protocol registry under the POP_GATEWAY key, which is the RootGatewayDispatcher deployed against this controller; the dispatcher is the contract that actually proves substrate Root authority before forwarding here.

Today the Pop gateway does not write a standalone user-status mapping. It materialises the PoP flow through gateway-issued labels, PoP resolver records, and reservation queue state; user tier checks for public pricing still come from the personhood precompile/context read.

The first, reserveBaseName, mints a lite-person username to a user. The gateway-facing input is a stem.suffix shape: a single DNS label followed by exactly one dot and a digits-only suffix of exactly two digits (for example michal.03). The controller normalises that input by stripping the dot before classification, pricing, and minting, so the on-chain label is always flat (michal.03 becomes michal03). Inputs with more than one dot, no dot, a non-digit suffix, or a suffix length other than two digits are rejected at the boundary. The stem may be any DNS-valid label of at least six characters, not only the 6 to 8 of the public PopLite tier; only governance-reserved stems (five characters or fewer) are rejected. A lite username whose stem is nine characters or longer classifies as NoStatus for public pricing and transfers, so its lite status is an issuance property rather than an economic tier. The call also persists the user's chat key on the PoP resolver and optionally enqueues a reservation for a full-person base name the user intends to claim later.

The second, registerBaseName, mints a full-person username. Whether the call is a claim against a prior lite reservation or a fresh standalone registration is derived from on-chain reservation state; the caller does not choose. The link argument selects the chat-key source: inherit from a prior lite label, or accept a fresh one in the payload. When inheriting, the call also writes the liteLink (full => lite) and fullClaim (lite => full) records on the PoP resolver in the same transaction so downstream consumers can resolve either direction without scanning events.

Each base label carries a head/tail-indexed reservation queue with a capacity of MAX_RESERVATION_QUEUE and a governance-configurable reservationDuration. The queue head is mirrored into PopRules on every head transition (enqueue-from-empty, expiry-driven promotion, non-expiry head removal, claim-wipes-queue), so the public commit-reveal flow sees the same cross-flow lock through its existing PopRules price check. The gateway path is symmetric: registerBaseName consults the live PopRules slot before mint and rejects with `NotHolder` when another user holds the stem, so PopRules is the single cross-flow authority in both directions. registerBaseName additionally rejects lite-classified labels (those belong on reserveBaseName) and governance-reserved labels with `InvalidBaseLabel`. Expiry advancement is permissionless: anyone can call expireReservation to garbage-collect a stale head, which is what the pallet does on its own cadence.

#### Early testnet quirk: LabelStore deployment

Pop-gateway issuances mint the name and persist its label, but LabelStore deployment is deferred for users who have not yet interacted with the protocol from their own address. The current pallet-revive runtime does not let substrate Root deploy contracts on behalf of an account it does not control, so the per-user LabelStore cannot be created at the moment the gateway writes. The controller stamps a pending-claim entry instead, and the user calls claimLabelStore once from their own address to settle the store. The pending-claim entries have a bounded TTL (expirePendingClaim is permissionless) so the slot frees itself if a user never claims. When the runtime supports root-origin contract deployment, the deferred path collapses to a no-op and the issuance flow becomes one transaction end-to-end. This is a runtime limitation, not a protocol design choice.

Operational consequence for transfers: the registrar derives the transfer-floor price by reading the label from the sender's LabelStore. A gateway-issued name held by a user who has not yet called claimLabelStore has no readable label on the sender side, so `_quoteTransferFee` returns zero regardless of the recipient's tier. Until the holder settles their LabelStore, a downward transfer (for example PopFull to NoStatus) does not charge the cross-tier friction it would otherwise owe. Clients that consume gateway-issued names should treat claimLabelStore as a prerequisite for accurate transfer-time pricing, not just for label discovery.

### RootGatewayDispatcher

Non-upgradeable shim that translates a substrate Root-origin dispatch into an EVM-observable authority on the PoP controller. The dispatcher is the direct callee of the Root runtime origin, asks the revive System precompile whether its caller is Root, and forwards the calldata to the controller via a regular message call only when that check passes. The forwarded call lands on the controller proxy with the dispatcher as the immediate caller, which the controller authorises against the address registered on the protocol registry under POP_GATEWAY.

Hosting the Root check in a separate, non-proxy contract is what makes it work at all. The revive System precompile is only meaningful in the frame that is the direct callee of Root, and a UUPS implementation runs inside the proxy's delegatecall, so the controller cannot ask the precompile from its own frame. The dispatcher's target is immutable, set at construction to the controller proxy it serves, and the dispatcher holds no storage of its own and never delegatecalls, so it cannot be repurposed as an arbitrary-target proxy. Rotating the dispatcher is a single set call on the protocol registry; the controller picks up the new gateway on its next call without an upgrade.

The dispatcher exists to work around a runtime limitation: the substrate Root origin is not propagated through delegatecalls, so a UUPS implementation running inside its proxy's delegatecall frame cannot observe Root authority directly. Routing gateway calls through the non-proxy dispatcher restores a frame in which the Root check is meaningful. When the runtime propagates origin through delegatecalls, the controller can verify Root from its own frame and the dispatcher becomes unnecessary. This is a runtime limitation, not a protocol design choice.

### DotnsRegistrar

ERC721-backed registrar that mints ownership of label IDs (labelhashes). Minting is restricted to every address in the controllers mapping; the mapping is owner-gated through addController and removeController. Every other contract in the system that needs to check "is this address authorised to drive name state?" consults this mapping rather than keeping a parallel list, which is what lets multiple controllers coexist on the same registrar without per-contract configuration changes.

### DotnsRegistry

Forward registry mapping node to (owner, resolver) and supporting subnode creation. When a base name is minted on the registrar, the matching controller wires the node to the new owner through this registry. Privileged node wiring defers to the same controllers mapping on the registrar, so both controllers can write without the registry tracking controllers of its own.

Subnames are created by the base-name owner. A subname carries its own (owner, resolver) and can in turn carry subnames, so the registry is the place the name hierarchy actually lives.

The registry exposes isAuthorised(node, account) as the canonical check for whether an address may manage a node: the stored owner for a subname, or the ERC-721 holder, a single-token approvee, or an operator-for-all on the registrar for a tokenised name. Sibling contracts consult this view so a single registrar-level approval delegates management across the protocol rather than each contract maintaining its own approval list.

### PopRules

PoP-aware name classification and pricing. Classification reads the label's **stem length** (the character count after stripping the trailing digit suffix) and the trailing digit count itself, then maps to one of four tiers: NoStatus (stem of 9+ characters, open to anyone for a flat deposit, with zero or exactly two trailing digits permitted), PopLite (stem of 6-8 characters with exactly two trailing digits, gateway-issued to lite-verified users), PopFull (stem of 6-8 characters with no trailing digits, requires full-person verification), and Reserved (stem of 5 characters or fewer, governed by the protocol). Labels carrying one trailing digit or more than two trailing digits are rejected at the classifier. The classification determines the price and the eligibility gate the commit-reveal controller enforces.

#### Classification examples and failure modes

The classifier bands on the stem, not the total label length. The stem is the label after removing any trailing digits. Trailing digit count must be zero or exactly two; a one-digit suffix and suffixes longer than two digits are invalid before tier eligibility is considered.

| Label        | Stem       | Trailing digits | Classification                        | Eligible public path | Notes                                                                                                             |
| ------------ | ---------- | --------------: | ------------------------------------- | -------------------- | ----------------------------------------------------------------------------------------------------------------- |
| alice12      | alice      |               2 | Reserved                              | Whitelist only       | The stem is five characters, so the two-digit suffix does not make it PopLite.                                    |
| andrew01     | andrew     |               2 | PopLite                               | Pop gateway only     | Valid lite shape: six-character stem plus system-supplied two-digit suffix.                                       |
| alicebob42   | alicebob   |               2 | PopLite                               | Pop gateway only     | Eight-character stem plus two digits; total length is ten.                                                        |
| andrew       | andrew     |               0 | PopFull                               | PopFull user         | Canonical full-person base name.                                                                                  |
| andrew1      | andrew     |               1 | Rejected                              | None                 | One trailing digit has no protocol meaning.                                                                       |
| andrewsays   | andrewsays |               0 | NoStatus                              | Anyone               | NoStatus self-registration pays the flat refundable deposit.                                                      |
| andrewsays01 | andrewsays |               2 | NoStatus                              | Anyone               | Long stem remains NoStatus even with a two-digit suffix.                                                          |
| andrew123    | andrew     |               3 | Rejected                              | None                 | More than two trailing digits is invalid.                                                                         |
| andrew.01    | n/a        |             n/a | Rejected by public label validator    | None                 | Dots are not valid in the public flat label. The Pop gateway accepts stem.suffix and normalises it to stemsuffix. |
| Andrew01     | n/a        |             n/a | Rejected by canonical label validator | None                 | Labels must be lowercase ASCII DNS labels.                                                                        |

Tier assignment is read on every pricing call, not stored: PopRules queries the alias-accounts personhood precompile at DotnsConstants.PERSONHOOD with the dotns context (bytes32("dotns")), and translates the returned status byte into a PopStatus (0=NoStatus, 1=PopLite, 2=PopFull). Unknown tier bytes collapse to NoStatus, so a future precompile addition fails closed rather than silently being treated as a higher tier. There is no on-chain self-attestation; users obtain personhood off-chain through the People-chain ring proof and the alias-accounts pallet propagates the result via XCM.

Classification is not the same thing as effective holder context. A long label such as andrewsays is always a NoStatus-tier label by shape, but it may be held by a PopFull, PopLite, or NoStatus account. Consumers that need to know what rules apply to that live name should combine three reads: classify the label, query the registrar owner, then query the owner's dotns-context PoP status through the precompile or gateway-written state. The escrow position is the economic qualifier: if the token has an active release position with a non-zero amount, it came through the refundable NoStatus deposit path; if no such deposit exists, a verified holder can own the same long label without it being deposit-backed. In other words, andrewsays does not become a PopFull-tier label when a PopFull user owns it, but the owner can still be PopFull for transfer pricing, reverse resolution, and UI display.

Whitelisting is the exception path for users or organisations that need to register without satisfying the live PoP tier check. DotNS still does not accept self-attestation: the contracts only consume PoP status from the personhood precompile, and a user cannot set or prove their own status inside DotNS. Instead, the public registrar controller has an owner-managed whitelist for registerReserved, which bypasses the PoP pricing gate for approved addresses while still using the normal commit-reveal and availability checks.

To request a whitelist entry, open a Whitelist Request issue in this repository. The issue is labelled whitelist-request by the template and must include the address, address type, target network (Paseo V2 or Paseo Review), and a clear description of why the PoP bypass is needed. A maintainer can approve the request by applying whitelist-approved, after which the workflow checks account mapping on the selected network and executes the on-chain whitelist transaction. Whitelisting does not register a name, reserve a label, or bypass ownership rules; it only allows the approved address to use the reserved registration path without a PoP status.

For the operator-side mechanics, granting the whitelist-operator role, granting it to many operators, and whitelisting one or many addresses through the dotNS SDK CLI, the hosted app, or `cast`, see the [Whitelisting](./DEPLOYMENTS.md#whitelisting) section in DEPLOYMENTS.md.

PopRules also holds the cross-flow reservation table for base names. Two write paths share one mapping keyed by the bare stem. The first is used by the commit-reveal controller during a lite registration: it classifies the incoming label, strips the trailing digits, and writes the bare stem. The second is used by the PoP controller on every reservation-queue head transition: it takes a bare stem directly and rejects the update when the slot is held by a different user, so the caller's local queue bookkeeping never silently diverges from the PopRules state.

Two read paths, priceWithCheck and priceWithoutCheck, are what the public flow consults. Both strip trailing digits before looking up the reservation, so any live entry on a bare stem blocks registrations of any variant under that stem for the reservation window (12 weeks by default).

### DotnsReverseResolver

Reverse records mapping an address to its primary name, with two write paths. The first, setReverseName, is the controller-only seeder: when a direct reserved registration lands and the registrant has no existing primary, the commit-reveal controller calls this entry point so a subsequent reserved registration does not silently overwrite the primary. Writes through this path are restricted to the addresses registered under CONTROLLER and REGISTRAR on the protocol registry. The second, claimReverseRecord, is the self-service path open to any current name owner: the caller hands in a label and the resolver checks that registrar.ownerOf(namehash(label)) equals the caller before overwriting their reverse entry. Past ownership is never sufficient; the registrar is the single source of truth for the gate.

Reads are open but fail-closed: nameOf(address) re-validates current ownership against the registrar before returning the stored name, so an address that has transferred their primary away resolves to the empty string until they claim a new name they currently hold. The protocol still best-effort clears reverse entries on transfer (cheaper reads, no behavioural change), but the security guarantee is the fail-closed read, not the eager clear.

### DotnsContentResolver

Stores contenthash and text records per node. This is where external content links (for example IPFS hashes) and arbitrary key-value text records (for example social handles, verification metadata) live. Writes accept the node owner, any address the registry recognises as authorised for the node through isAuthorised (the ERC-721 holder, a single-token approvee, or an operator-for-all on the registrar), or an operator approved directly on this resolver; reads are open. The registry-recognised path lets a registrar-level name admin manage records without a separate grant, while the resolver-local operator is a narrower record-only delegation that confers no power over ownership or transfer. Authority is evaluated against the current owner on every write, so transferring the name reassigns write access automatically.

Choosing a delegation mechanism:

| Goal                                                                                                 | Use                                                  | Why                                                                                                                                                                                                     |
| ---------------------------------------------------------------------------------------------------- | ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Delegate full control of one name, including the right to transfer it, automatically revoked on sale | registrar `approve(operator, tokenId)`               | Single-token approval. ERC-721 clears it on every transfer, so it cannot follow the name to a buyer.                                                                                                    |
| Delegate full control of all your names, current and future, including transferring them             | registrar `setApprovalForAll(operator, true)`        | The name-admin role. Persists until revoked and spans every name you hold. It grants transfer power, so grant it only to fully trusted managers; this is the approval marketplaces and escrows require. |
| Delegate record edits only, with no power over ownership or transfer                                 | content resolver `setApprovalForAll(operator, true)` | The narrowest grant. Resolver-local and record-scoped: the operator can set text and contenthash but cannot transfer the name or change its owner.                                                      |

Revoke any grant with the inverse call (`approve(address(0), tokenId)` or `setApprovalForAll(operator, false)`). Because every write re-reads the current owner, a transfer drops all delegates the prior owner had set.

### DotnsResolver

Stores forward-resolution address records per node. This is the conventional "name to address" lookup: a client has a .dot name and wants to know the Ethereum address behind it. Writes require node ownership; reads are open.

### DotnsPopResolver

Per-node resolver for records produced by the Proof-of-Personhood flow. Three record kinds. The chat key is ECDH public-key bytes keyed by node; it is written by the PoP controller during a lite reservation and during any claim path that inherits from a prior lite entry, and is what gives verified users an on-chain discovery channel for end-to-end encrypted messaging. The lite link answers "which lite username did this full name claim from?" and is keyed by the full-person node. The full claim is the reverse direction: it answers "which full name did this lite user claim?" and is keyed by the lite labelhash. The forward and reverse links are written by the same call, so they stay in lockstep; downstream consumers that look up by lite username (Nova's pallet, for one) resolve the full name without scanning events.

Writer authorisation is dynamic: the PoP controller address is fetched from the protocol registry on every write. Rotating the PoP controller is a single set call on the protocol registry with no resolver upgrade required.

### DotnsProtocolRegistry

On-chain lookup table mapping well-known bytes32 keys (declared in DotnsConstants) to contract addresses. Every DotNS contract resolves its siblings through this registry at runtime.

Without it, each contract would store direct addresses to every contract it calls. An upgrade that changes one address would require a separate owner transaction for every contract that references it. The protocol registry reduces this to one: update the key in the registry, and every caller picks up the new address on its next call. The indirection also means a governance-driven rotation of, say, the PoP controller does not break any consumer that has already been deployed.

The registered keys include REGISTRAR, CONTROLLER, REGISTRY, REVERSE_RESOLVER, RESOLVER, CONTENT_RESOLVER, POP_RULES, STORE_FACTORY, POP_CONTROLLER, POP_RESOLVER, NAME_ESCROW, MULTICALL3, and POP_GATEWAY.

### Multicall3

Generic arbitrary-target batching helper using the standard Multicall3 interface. It is protocol infrastructure rather than a dotNS-specific authorisation surface: anyone can call it, and each target contract still enforces its own permissions.

For read batching, Multicall3 lets clients collect several results from the same block through one call. For write batching, callers must remember that target contracts observe Multicall3 as the caller, not the original externally owned account. That means public owner-gated dotNS writes should not be routed through Multicall3 unless the target flow explicitly supports that caller model.

### StoreFactory, LabelStore, and UserStore

Stores are the per-user storage layer. They exist because two query paths the rest of the system needs are not answerable from anywhere else: "what names has this address ever held?" cannot be served by resolvers (keyed per-node) or the registry (live ownership only, no history), and "what user-controlled records does this address publish?" has nowhere on a resolver to live since the data is not bound to any one name. Each address gets at most one of each store, forever, and the factory is the single source of truth for which store belongs to which user.

LabelStore is the protocol-managed half. The registrar and the controller set write a label entry once and the slot is permanently locked. The invariant is labels only: every per-name record category (reverse, content, forward address, chat key, lite link) goes to a dedicated resolver, and the Store stays the durable per-owner registration ledger. Because entries are append-only, transferring a name writes a fresh entry on the recipient and leaves the sender's locked entry in place, so LabelStore doubles as the address's lifetime-of-ownership ledger while the registry continues to answer for live ownership.

UserStore is the user-claimed half. The bound owner is the only writer and prior values are snapshotted into a per-key history. It exists so that user-controlled records that do not belong to a name have a home that bills the user's own contract rather than polluting a shared resolver. The labels-only invariant is preserved by the split: nothing user-written ever lands on the protocol-managed side.

### Deployments

Current network addresses are listed in [DEPLOYMENTS.md](./DEPLOYMENTS.md).

### Build and test

Builds and tests are run with Foundry. Fork tests use the local Paseo Asset Hub adapter described in [DEPLOYMENTS.md](./DEPLOYMENTS.md); ordinary unit, fuzz, and invariant tests run against Foundry's in-process EVM.

## Security

Before deploying it for real use cases, you are responsible for:

- Reviewing the code yourself, we publish a reference, not a hardened production build
- Checking that the dependencies are up to date and free of known vulnerabilities
- Securing your own fork or deployment environment (keys, secrets, network configuration)
- Tracking the latest tagged release/commits for security fixes; older releases are not backported (exceptions might apply)

For Parity's security disclosure process, and Bug Bounty program, feel free to visit: https://parity.io/bug-bounty

## Known limitations

The protocol carries a handful of constraints worth knowing before deploying or building against it. Most stem from the current pallet-revive runtime rather than from protocol design, and collapse to a no-op once the runtime gains the corresponding capability. [KNOWN_ISSUES.md](./KNOWN_ISSUES.md) is the consolidated reference; each issue is also described in full where the relevant contract is documented below.

- **Deferred LabelStore deployment** (runtime). See [DotnsPopController](#early-testnet-quirk-labelstore-deployment).
- **Transfer fee is zero until the store is settled** (runtime). See [DotnsPopController](#early-testnet-quirk-labelstore-deployment).
- **Root origin is not propagated through delegatecalls** (runtime). See [RootGatewayDispatcher](#rootgatewaydispatcher).
- **No standalone user-status mapping** (current implementation). See [DotnsPopController](#dotnspopcontroller).

## License

Licensed under the MIT License. See [LICENSE](./LICENSE). External interface definitions under `contracts/external/` retain their upstream licences (the SPDX header in each file is authoritative). Security policy and disclosure: see [SECURITY.md](./SECURITY.md).
