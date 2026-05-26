# Dotns

Smart contracts for registering .dot names on Polkadot.

DotNS is a naming system for Polkadot. An account can register a .dot name, receive an ERC721 token that represents ownership of that name, attach records to it (addresses, text, content hashes, chat keys), and create subnames beneath it. Two independent issuance paths coexist on the same underlying registrar: a public commit-reveal path for anyone who wants a name, and a Proof-of-Personhood gateway path that issues lite-person and full-person usernames on behalf of verified users. Every piece of state the protocol surfaces is readable through public view functions on the chain itself, so a client needs only a node and a small set of well-known contract addresses to answer any question about the system.

## Diagrams

### Registration flow

![Registration flow](./diagrams/registration.png)

### Subnode creation flow

![Subnode creation](./diagrams/subname.png)

### CID flow (Bulletin Chain)

![CID flow](./diagrams/cid.png)

### System diagram

![System diagram](./diagrams/system.png)

## Deployment and operations

Current network addresses and deployment notes are listed in [DEPLOYMENTS.md](./DEPLOYMENTS.md).

## Economics

dotNS uses a single tunable constant, written **D** throughout the protocol. D is the starting price used by PopRules and equals ten DOT at launch; governance can adjust it under the same gate as the upgrade authority. D is the only money quantity the protocol charges; everything else is a composition of D with zero.

D plays two distinct roles. As a **deposit** it is the refundable lock a NoStatus user posts to register a NoStatus-tier label; the deposit is bound to the name, not to the depositor, so it travels with the NFT on every transfer and only unlocks when the current holder releases the name back to escrow. Transferring a funded name forfeits the deposit to the new holder, who inherits the locked D and the right to release later. As a **friction** charge it is the non-refundable amount a sender pays on a cross-tier downward or reach-floor transfer. The two flows are economically distinct: the deposit gates a count of names (one D per NoStatus name in existence), the friction gates the rate of tier laundering.

### Registration matrix

The public controller computes the registration charge as the greater of the owner-side price and the payer-to-owner downward friction; it does not add the two together. The single charge becomes a refundable deposit on a direct NoStatus registration and becomes non-refundable reserve funding on a cross-payer registration.

| Owner tier      | Reserved (stem ≤5) | PopFull-tier (stem 6-8, no digits) | PopLite-tier (stem 6-8, two digits) | NoStatus-tier (stem ≥9) |
|---|---|---|---|---|
| **NoStatus user**     | rejected | rejected | rejected | direct: pays D into deposit |
| **PopLite user**      | rejected | rejected | gateway-only; free | free |
| **PopFull user**      | rejected | free | gateway-only; free | free |
| **Whitelisted address** | free | free | free | free |

Cross-payer registrations pay the greater of the owner-side price and the transfer-floor amount into the reserve. Reserved labels remain forbidden on the cross-payer path because the owner-side gate still rejects them. Whitelist registrations go through the same commit-reveal pipeline as the public path.

### Transfer matrix

The registrar consults PopRules for the transfer floor. A transfer pays D whenever the recipient's tier is strictly below the sender's, or whenever the recipient cannot reach the label's required tier. A stale PopFull-tier name landing with a PopLite holder, for example, can still owe friction even when the holder-to-holder move otherwise looks same-tier. Same-tier and upward transfers between holders of the label's own class are free of friction.

The deposit, when present, is bound to the name and rides with it on every transfer. The escrow position is rebound to the new holder rather than refunded; only releasing the name back to escrow ever unlocks the locked D. Transferring a funded name is therefore a real forfeiture: the sender hands the locked deposit over to the recipient along with the NFT.

| Sender → Recipient                | Friction (to insurance) | Deposit movement |
|---|---|---|
| NoStatus → NoStatus (same tier)   | 0                      | Travels with the name; position rebinds to recipient |
| NoStatus → PopLite or PopFull     | 0                      | Travels with the name; position rebinds to recipient |
| PopLite → NoStatus                | D                      | Any inherited deposit travels with the name |
| PopLite → PopLite (same)          | 0                      | Any inherited deposit stays bound to the name |
| PopLite → PopFull (upward)        | 0                      | Any inherited deposit stays bound to the name |
| PopFull → NoStatus                | D                      | Any inherited deposit travels with the name |
| PopFull → PopLite (downward)      | D                      | Any inherited deposit stays bound to the name |
| PopFull → PopFull (same)          | 0                      | Any inherited deposit stays bound to the name |

The friction is constant and additive across downward hops. Every step that crosses a tier boundary downward charges D independently, so routing a name through intermediary tiers never costs less than the equivalent direct transfer. Laundering pays at least as much as the route it tries to avoid. Because the deposit follows the NFT, a NoStatus user cannot recover their D by handing the name to a fresh address and registering again; the only path back to D is releasing the current name into escrow. This binds Sybil cost to one D per live NoStatus name in existence, independent of how often names change hands.

### Refund and cooldown model

The escrow maintains two separate pull-payment ledgers. The split is deliberate: one ledger is for immediate overpayment withdrawals, and the other is for refunds that must wait behind a cooldown.

- **Overpayment ledger.** No cooldown. Used only as the fallback when a direct registration overpayment cannot be returned to the sender inline.
- **Refund ledger.** Every refund has its own cooldown clock. Used for the deposit unlocked when a holder releases a funded name back to escrow, and for transfer-fee overpayments. Transfers never credit the refund ledger because the position rides with the name; only release-and-withdraw does.

Only registrations try to return surplus immediately. Every other refund path waits behind its own cooldown. The cooldown is bounded to minutes: it is the window between release and reclaim during which the original payer has an uncontested chance to pull their refund before the controller hands the name out again, not a long-lived lock. Governance can tune it within that band.

Clients can enumerate pending refunds through the escrow's public refund views. Pagination is capped so refund discovery remains bounded.

## Contracts

Two controllers sit on top of a single registrar and a single protocol registry. The registrar holds the ERC721 token per name; the registry holds the forward node => (owner, resolver) mapping and subname hierarchy; the resolvers hold per-name records; the protocol registry is the indirection layer through which every contract resolves its siblings at runtime. Controllers are the entry points: they mint names and drive the side effects. Neither controller imports the other. The layers underneath arbitrate collision handling: ERC721 uniqueness on the registrar, and a single reservation table on PopRules that both flows read through.

### DotnsRegistrarController

Commit-reveal controller for the public registration path. A caller first submits a commitment hash, waits out the minimum commitment age, then reveals the registration parameters alongside the payment. The controller validates the commitment, routes price and eligibility through PopRules, and orchestrates every side effect of a successful registration: the mint on the registrar, the forward wire-up on the registry, the reverse record on the reverse resolver, the immutable Store write, and any refund owed on overpayment. Acceptable input is a single DNS label; governance-reserved labels are rejected at the pricing layer.

### DotnsPopController

Dedicated controller for the Proof-of-Personhood gateway flow. Lives behind its own UUPS proxy with its own storage and is registered on the registrar via addController alongside the commit-reveal controller. Its gated entry points are callable only from the address resolved through the protocol registry under the POP_GATEWAY key, which is the RootGatewayDispatcher deployed against this controller; the dispatcher is the contract that actually proves substrate Root authority before forwarding here.

Today the Pop gateway does not write a standalone user-status mapping. It materialises the PoP flow through gateway-issued labels, PoP resolver records, and reservation queue state; user tier checks for public pricing still come from the personhood precompile/context read.

The first, reserveBaseName, mints a lite-person username to a user. The gateway-facing input is a stem.suffix shape: a single DNS label followed by exactly one dot and a digits-only suffix of exactly two digits (for example michal.03). The controller normalises that input by stripping the dot before classification, pricing, and minting, so the on-chain label is always flat (michal.03 becomes michal03). Inputs with more than one dot, no dot, a non-digit suffix, or a suffix length other than two digits are rejected at the boundary. The call also persists the user's chat key on the PoP resolver and optionally enqueues a reservation for a full-person base name the user intends to claim later.

The second, registerBaseName, mints a full-person username. Whether the call is a claim against a prior lite reservation or a fresh standalone registration is derived from on-chain reservation state; the caller does not choose. The link argument selects the chat-key source: inherit from a prior lite label, or accept a fresh one in the payload. When inheriting, the call also writes the liteLink (full => lite) and fullClaim (lite => full) records on the PoP resolver in the same transaction so downstream consumers can resolve either direction without scanning events.

Each base label carries a head/tail-indexed reservation queue with a capacity of MAX_RESERVATION_QUEUE and a governance-configurable reservationDuration. The queue head is mirrored into PopRules on every head transition (enqueue-from-empty, expiry-driven promotion, non-expiry head removal, claim-wipes-queue), so the public commit-reveal flow sees the same cross-flow lock through its existing PopRules price check. Expiry advancement is permissionless: anyone can call expireReservation to garbage-collect a stale head, which is what the pallet does on its own cadence.

#### Early testnet quirk: LabelStore deployment

Pop-gateway issuances mint the name and persist its label, but LabelStore deployment is deferred for users who have not yet interacted with the protocol from their own address. The current pallet-revive runtime does not let substrate Root deploy contracts on behalf of an account it does not control, so the per-user LabelStore cannot be created at the moment the gateway writes. The controller stamps a pending-claim entry instead, and the user calls claimLabelStore once from their own address to settle the store. The pending-claim entries have a bounded TTL (expirePendingClaim is permissionless) so the slot frees itself if a user never claims. When the runtime supports root-origin contract deployment, the deferred path collapses to a no-op and the issuance flow becomes one transaction end-to-end. This is a runtime limitation, not a protocol design choice.

Operational consequence for transfers: the registrar derives the transfer-floor price by reading the label from the sender's LabelStore. A gateway-issued name held by a user who has not yet called claimLabelStore has no readable label on the sender side, so `_quoteTransferFee` returns zero regardless of the recipient's tier. Until the holder settles their LabelStore, a downward transfer (for example PopFull to NoStatus) does not charge the cross-tier friction it would otherwise owe. Clients that consume gateway-issued names should treat claimLabelStore as a prerequisite for accurate transfer-time pricing, not just for label discovery.

### RootGatewayDispatcher

Non-upgradeable shim that translates a substrate Root-origin dispatch into an EVM-observable authority on the PoP controller. The dispatcher is the direct callee of the Root runtime origin, asks the revive System precompile whether its caller is Root, and forwards the calldata to the controller via a regular message call only when that check passes. The forwarded call lands on the controller proxy with the dispatcher as the immediate caller, which the controller authorises against the address registered on the protocol registry under POP_GATEWAY.

Hosting the Root check in a separate, non-proxy contract is what makes it work at all. The revive System precompile is only meaningful in the frame that is the direct callee of Root, and a UUPS implementation runs inside the proxy's delegatecall, so the controller cannot ask the precompile from its own frame. The dispatcher's target is immutable, set at construction to the controller proxy it serves, and the dispatcher holds no storage of its own and never delegatecalls, so it cannot be repurposed as an arbitrary-target proxy. Rotating the dispatcher is a single set call on the protocol registry; the controller picks up the new gateway on its next call without an upgrade.

### DotnsRegistrar

ERC721-backed registrar that mints ownership of label IDs (labelhashes). Minting is restricted to every address in the controllers mapping; the mapping is owner-gated through addController and removeController. Every other contract in the system that needs to check "is this address authorised to drive name state?" consults this mapping rather than keeping a parallel list, which is what lets multiple controllers coexist on the same registrar without per-contract configuration changes.

### DotnsRegistry

Forward registry mapping node to (owner, resolver) and supporting subnode creation. When a base name is minted on the registrar, the matching controller wires the node to the new owner through this registry. Privileged node wiring defers to the same controllers mapping on the registrar, so both controllers can write without the registry tracking controllers of its own.

Subnames are created by the base-name owner. A subname carries its own (owner, resolver) and can in turn carry subnames, so the registry is the place the name hierarchy actually lives.

### PopRules

PoP-aware name classification and pricing. Classification reads the label's **stem length** (the character count after stripping the trailing digit suffix) and the trailing digit count itself, then maps to one of four tiers: NoStatus (stem of 9+ characters, open to anyone for a flat deposit, with zero or exactly two trailing digits permitted), PopLite (stem of 6-8 characters with exactly two trailing digits, gateway-issued to lite-verified users), PopFull (stem of 6-8 characters with no trailing digits, requires full-person verification), and Reserved (stem of 5 characters or fewer, governed by the protocol). Labels carrying one trailing digit or more than two trailing digits are rejected at the classifier. The classification determines the price and the eligibility gate the commit-reveal controller enforces.

#### Classification examples and failure modes

The classifier bands on the stem, not the total label length. The stem is the label after removing any trailing digits. Trailing digit count must be zero or exactly two; a one-digit suffix and suffixes longer than two digits are invalid before tier eligibility is considered.

| Label | Stem | Trailing digits | Classification | Eligible public path | Notes |
| --- | --- | ---: | --- | --- | --- |
| alice12 | alice | 2 | Reserved | Whitelist only | The stem is five characters, so the two-digit suffix does not make it PopLite. |
| andrew01 | andrew | 2 | PopLite | Pop gateway only | Valid lite shape: six-character stem plus system-supplied two-digit suffix. |
| alicebob42 | alicebob | 2 | PopLite | Pop gateway only | Eight-character stem plus two digits; total length is ten. |
| andrew | andrew | 0 | PopFull | PopFull user | Canonical full-person base name. |
| andrew1 | andrew | 1 | Rejected | None | One trailing digit has no protocol meaning. |
| andrewsays | andrewsays | 0 | NoStatus | Anyone | NoStatus self-registration pays the flat refundable deposit. |
| andrewsays01 | andrewsays | 2 | NoStatus | Anyone | Long stem remains NoStatus even with a two-digit suffix. |
| andrew123 | andrew | 3 | Rejected | None | More than two trailing digits is invalid. |
| andrew.01 | n/a | n/a | Rejected by public label validator | None | Dots are not valid in the public flat label. The Pop gateway accepts stem.suffix and normalises it to stemsuffix. |
| Andrew01 | n/a | n/a | Rejected by canonical label validator | None | Labels must be lowercase ASCII DNS labels. |

Tier assignment is read on every pricing call, not stored: PopRules queries the alias-accounts personhood precompile at DotnsConstants.PERSONHOOD with the dotns context (bytes32("dotns")), and translates the returned status byte into a PopStatus (0=NoStatus, 1=PopLite, 2=PopFull). Unknown tier bytes collapse to NoStatus, so a future precompile addition fails closed rather than silently being treated as a higher tier. There is no on-chain self-attestation; users obtain personhood off-chain through the People-chain ring proof and the alias-accounts pallet propagates the result via XCM.

Classification is not the same thing as effective holder context. A long label such as andrewsays is always a NoStatus-tier label by shape, but it may be held by a PopFull, PopLite, or NoStatus account. Consumers that need to know what rules apply to that live name should combine three reads: classify the label, query the registrar owner, then query the owner's dotns-context PoP status through the precompile or gateway-written state. The escrow position is the economic qualifier: if the token has an active release position with a non-zero amount, it came through the refundable NoStatus deposit path; if no such deposit exists, a verified holder can own the same long label without it being deposit-backed. In other words, andrewsays does not become a PopFull-tier label when a PopFull user owns it, but the owner can still be PopFull for transfer pricing, reverse resolution, and UI display.

Whitelisting is the exception path for users or organisations that need to register without satisfying the live PoP tier check. DotNS still does not accept self-attestation: the contracts only consume PoP status from the personhood precompile, and a user cannot set or prove their own status inside DotNS. Instead, the public registrar controller has an owner-managed whitelist for registerReserved, which bypasses the PoP pricing gate for approved addresses while still using the normal commit-reveal and availability checks.

To request a whitelist entry, open a Whitelist Request issue in this repository. The issue is labelled whitelist-request by the template and must include the address, address type, target network (Paseo V2 or Paseo Review), and a clear description of why the PoP bypass is needed. A maintainer can approve the request by applying whitelist-approved, after which the workflow checks account mapping on the selected network and executes the on-chain whitelist transaction. Whitelisting does not register a name, reserve a label, or bypass ownership rules; it only allows the approved address to use the reserved registration path without a PoP status.

PopRules also holds the cross-flow reservation table for base names. Two write paths share one mapping keyed by the bare stem. The first is used by the commit-reveal controller during a lite registration: it classifies the incoming label, strips the trailing digits, and writes the bare stem. The second is used by the PoP controller on every reservation-queue head transition: it takes a bare stem directly and rejects the update when the slot is held by a different user, so the caller's local queue bookkeeping never silently diverges from the PopRules state.

Two read paths, priceWithCheck and priceWithoutCheck, are what the public flow consults. Both strip trailing digits before looking up the reservation, so any live entry on a bare stem blocks registrations of any variant under that stem for the reservation window (12 weeks by default).

### DotnsReverseResolver

Reverse records mapping an address to its primary name, with two write paths. The first, setReverseName, is the controller-only seeder: when a direct reserved registration lands and the registrant has no existing primary, the commit-reveal controller calls this entry point so a subsequent reserved registration does not silently overwrite the primary. Writes through this path are restricted to the addresses registered under CONTROLLER and REGISTRAR on the protocol registry. The second, claimReverseRecord, is the self-service path open to any current name owner: the caller hands in a label and the resolver checks that registrar.ownerOf(namehash(label)) equals the caller before overwriting their reverse entry. Past ownership is never sufficient; the registrar is the single source of truth for the gate.

Reads are open but fail-closed: nameOf(address) re-validates current ownership against the registrar before returning the stored name, so an address that has transferred their primary away resolves to the empty string until they claim a new name they currently hold. The protocol still best-effort clears reverse entries on transfer (cheaper reads, no behavioural change), but the security guarantee is the fail-closed read, not the eager clear.

### DotnsContentResolver

Stores contenthash and text records per node. This is where external content links (for example IPFS hashes) and arbitrary key-value text records (for example social handles, verification metadata) live. Writes require node ownership or an approved operator; reads are open.

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
