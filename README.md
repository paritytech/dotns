> [!WARNING]
> This open source code is provided for research, experimentation, and developer education only. This code has not been audited, is actively experimental, and may contain bugs, vulnerabilities, or incomplete features. Use at your own risk.


# Dotns

Smart contracts for registering .dot names on Polkadot.

DotNS is a naming system for Polkadot. An account can register a .dot name, receive an ERC721 token that represents ownership of that name, attach records to it (addresses, text, content hashes, chat keys), and create subnames beneath it. Two independent issuance paths coexist on the same underlying registrar: a public commit-reveal path for anyone who wants a name, and a Proof-of-Personhood gateway path that issues lite-person and full-person usernames on behalf of verified users. Every piece of state the protocol surfaces is readable through public view functions on the chain itself, so a client needs only a node and a small set of well-known contract addresses to answer any question about the system.

## Diagrams

### System diagram

![System diagram](./diagrams/system.png)

## Deployment and operations

Deployment notes are in [DEPLOYMENTS.md](./DEPLOYMENTS.md). Network addresses are recorded in `deployments/<network>/<chain-id>.json` and published with each release.

### Cutting a release

A release publishes the contract ABIs and the deployed addresses as GitHub release assets, described in [RELEASE_ARTIFACTS.md](./RELEASE_ARTIFACTS.md). It does not deploy anything; deploying contracts to a network is a separate process, described in [DEPLOYMENTS.md](./DEPLOYMENTS.md).

Run **Publish Release Package** from the Actions tab, pick the branch to release from, and enter the version (`v0.5.5`). The workflow does the rest: it builds, tests, extracts the ABIs listed in [.github/abi-contracts.txt](./.github/abi-contracts.txt), generates the address and manifest files, creates the release as a draft with every asset attached, verifies the set against what the build produced, and only then publishes. Pushing a matching tag runs the same workflow, so `git tag v0.5.5 && git push origin v0.5.5` remains equivalent.

Pre-releases use **Publish Beta Package** with a suffixed version, `v0.5.5-rc1`. The version is the release identity; the `version` field in `package.json` is unrelated and nothing reads it.

Do not create releases through the GitHub UI's release form, or with `gh release create`. Both publish immediately, and because this repository has immutable releases enabled, a published release can no longer accept assets: only its title and notes stay editable. A release made that way carries no ABIs at all. The workflow rejects an already-published version before building, so the mistake fails in seconds rather than silently shipping an empty release.

If a run fails partway, re-run it from the Actions tab; the draft is updated rather than duplicated. One case needs a manual step: the upload replaces an asset of the same name but never removes others, so if the contract list changed since the failed run, the draft still carries the assets it no longer expects and the verification step will keep refusing to publish. Delete the draft and re-run. If the version has already been published, use a different one, since its assets cannot be changed.

## Economics

Every name admitted to public sale costs the same refundable deposit: 10 DOT at launch. The amount is not fixed in the registration path. It comes from a cost model resolved through the protocol registry under the `costModel` key, and governance can replace that model without touching the registrar or its storage. The launch model, `DotnsFlatPricing`, returns one deposit for every length. A length-sensitive scarcity curve, `DotnsScarcityPricing`, ships alongside it as a candidate for a later version but is not the registered default.

### Base length and the digit rule

Pricing and eligibility read a name's base length. An ordinary name is measured as written, digits included, so `andrew` is six characters and `andrew01` is eight. A lite-person username issued by the PoP gateway carries a separator and two allocated digits (`andrew.01`), and those come off first, so it measures its six-character stem. Base length decides which band a name falls in and who may register it; under the flat model it does not change the amount.

### What a name costs

Only names of nine characters or more are on public sale by default. The short-name switch, off at launch, keeps base lengths below nine off the public paid path. Every name on sale costs the flat deposit:

| Base length | Price | On public sale by default |
|---|---|---|
| 6 to 8 | 10 DOT | No, held behind the short-name switch |
| 9 or more | 10 DOT | Yes |
| 5 or fewer | not sold | issued at zero base cost through the reserved path |

### Who can register a name

Three bands share the one deposit.

| Base length | Who may register on the public paid path | Price |
|---|---|---|
| 9 or more | anyone, as NoStatus | 10 DOT |
| 6 to 8 | a verified person, and only while the short-name switch is on | 10 DOT |
| 5 or fewer | nobody on the public path | not sold; issued at zero base cost through the reserved path |

Personhood unlocks only the six-to-eight band. A no-digit name there needs full-person verification; a two-digit name needs lite-person verification. It gates who may buy, not the price: the deposit is the same one everyone pays.

Names shorter than nine characters are closed on the public paid path by default. A paid registration below nine reverts until governance opens the short-name market with a single switch. The switch gates the public paid path alone: the personhood gateway issues names of any length without it, and the reserved path does not consult it. It defaults off, so at launch only names of nine characters or more are for sale.

Names of five characters or fewer are never sold on the public path, which rejects a reserved-tier label outright. Such a name enters circulation only through the reserved path, which mints an available label at zero base cost with no deposit and no personhood check. That path is gated on a grant: the label must be bound to the intended owner on `DotnsNameWhitelist`, or the dispatch must be substrate Root. There is no treasury: no value moves when a reserved name is issued.

### Worked examples

The path decides whether the amount is a refundable deposit, a non-refundable fee, or nothing at all. Every amount below is the flat launch deposit of 10 DOT.

| Name | Base length | Path | Amount | Held as |
|---|---|---|---|---|
| `gavinwood` | 9 | public, own key | 10 DOT | refundable deposit |
| `gavinwood` | 9 | public, someone else pays | 10 DOT | protocol fee |
| `andrewsays` | 10 | public, own key | 10 DOT | refundable deposit |
| `andrew` | 6 | public, own key (switch on, full person) | 10 DOT | refundable deposit |
| `alicebob42` | 8 | public, own key (switch on, lite person) | 10 DOT | refundable deposit |
| any six-to-eight name | 6 to 8 | personhood gateway grant | none | no deposit, no fee |
| `andrew`, moved to a wallet that cannot clear its band | 6 | transfer | 10 DOT | protocol fee |

### Deposits and protocol fees

Registering a name under your own key locks a refundable deposit equal to the name's price. The deposit is bound to the name rather than to you, so it travels with the token on every transfer and unlocks only when the current holder releases the name back to escrow.

A name someone else pays for, and a transfer, pay a non-refundable fee instead. When a third party pays for another wallet's registration, the charge is the same owner-side price, with no separate friction added; it routes to a single protocol fee pot, and the owner's escrow slot is seeded with a zero amount so the release lifecycle stays reachable. A gateway grant carries neither a deposit nor a fee. The protocol fee pot only ever grows: it backs no refunds, and nothing burns, sweeps, or withdraws from it. Refunds draw solely on the separate per-asset reserve that deposits fund. A holder's own deposit is their money held in trust and is never moved into fees.

### Transfers re-price at the name's own length

Publicly registered names transfer freely and charge the name's own price, but only in two cases: the recipient cannot clear the name's band, or the move is a personhood downgrade, where the recipient's tier is lower than the sender's. Passing a six-character name to a wallet that could never have registered it costs the name's own price, so there is no cheap way to hand a band-gated name to a party who could not have earned it. A move between two wallets that both clear the band, and a move to the same address, cost nothing. The fee, when one is owed, settles into the protocol fee pot. The deposit, when present, rides with the name: the escrow position rebinds to the new holder rather than refunding, and only releasing the name back to escrow unlocks the locked deposit.

Names minted through the PoP gateway are soulbound: they stay bound to the person who earned them and cannot be transferred at all. Any transfer of a gateway-issued name reverts, and quoting a transfer fee for one reverts rather than returning a price. Everything else about the name works normally, so its owner still sets records, issues subnames, and manages the name.

### Versioned pricing

The cost model is chosen by governance and swapped, not upgraded. Registering a new model adds it under a fresh version and points the current version at it; earlier versions stay priceable, so a registration already committed against an earlier version settles at the amount it committed to. A commitment binds the version current when it is made, and the reveal reverts if it is presented at a different version, so a model change between commit and reveal cannot move the amount. Governance can also point the current version back at an earlier registered model.

### Release lifecycle

Releasing a name starts two independent clocks, and the distinction between them is what makes a released name both recoverable and recyclable.

| Clock | Length | What it gates |
|---|---|---|
| `withdrawAvailableAt` | release + `cooldown` (15 minutes at launch, at most 1 hour) | When the holder may credit the deposit to themselves through `withdraw` |
| `redeemableUntil` | release + `redeemWindow` (1 day at launch, governance may set 1 to 30 days) | When the holder's exclusive claim ends and `reclaim` opens to anyone |

Both are stamped at release time, so a governance change never moves the clocks on a name already released. Inside the redeem window the name belongs to its previous holder, and `DotnsRegistrar.available` reports false so no client advertises it as free. The holder has two mutually exclusive options:

- `redeem` returns the token and moves no value. The position keeps its recipient, asset and amount, so the deposit stays locked and the name lands back in its exact pre-release state, releasable again later on a fresh pair of clocks. This is the undo for an accidental release.
- `withdraw` credits the deposit and forfeits the right to redeem. A holder paid for the name cannot also take it back, otherwise they would hold a name no deposit backs.

Once `redeemableUntil` passes, `reclaim` is permissionless through the ordinary commit-reveal path, whether or not the previous holder ever withdrew. If the position still holds value, reclaim settles it: the amount is credited to the previous holder's pull-payment balance and stays claimable with no deadline. The value follows the departing holder; the name does not wait for them. Cross-paid registrations seed zero-amount positions, so those names have nothing to withdraw and nothing to settle.

Gateway-issued (soulbound) names never enter this lifecycle. Releasing a name transfers it into escrow custody, and a soulbound name reverts on any transfer, so it holds no position and has no release, redeem, or reclaim path. It stays with the person who earned it.

### Cost-model versioning

D and F are fixed for the life of a pricing model. Changing either means deploying a fresh model with the new values and registering it, at which point it becomes the current version; there is no live setter that edits the numbers in place. Governance can also point the current version back at an earlier registered model to roll a change back. An in-flight registration prices at the version it committed to, so a model change between commit and reveal leaves its cost unchanged.

### What governance controls

Governance sets D and F to whatever values it chooses. The contracts hold them coherent and nothing more: D above zero, F above zero and no greater than D, and D within a ceiling that keeps the six-character multiplication from overflowing. There is no cap on how high or low D goes and no limit on how fast it moves, so any rate limit or advance notice comes from the governance process rather than from these contracts. Governance also opens or closes the short-name market with the switch, tunes the release cooldown within its one-hour bound, sets the redeem window between 1 and 30 days, and sets the gateway's reservation duration. None of these controls lets governance seize, reassign, or destroy a name anyone already holds.

### Refund ledgers

The escrow keeps two separate pull-payment ledgers. One has no cooldown and serves as the fallback when a registration overpayment cannot be pushed back to the sender inline. The other gives every credit its own cooldown clock and holds transfer-fee overpayments. A deposit unlocked by releasing a funded name lands on the no-cooldown ledger; its delay comes instead from the position's own `withdrawAvailableAt` stamp, so once `withdraw` lands the credit is immediately pullable. Clients enumerate pending refunds through the escrow's public views, which page under a fixed cap so discovery stays bounded.

Clients that need the exact moment a released name becomes registrable should read `redeemableUntil` from `getReleasePosition` rather than polling `available`.

## Contracts

Two controllers sit on top of a single registrar and a single protocol registry. The registrar holds the ERC721 token per name; the registry holds the forward node => (owner, resolver) mapping and subname hierarchy; the resolvers hold per-name records; the protocol registry is the indirection layer through which every contract resolves its siblings at runtime. Controllers are the entry points: they mint names and drive the side effects. Neither controller imports the other. The layers underneath arbitrate collision handling: ERC721 uniqueness on the registrar, and a single reservation table on PopRules that both flows read through.

### DotnsRegistrarController

Commit-reveal controller for the public registration path. A caller first submits a commitment hash, waits out the minimum commitment age, then reveals the registration parameters alongside the payment. The controller validates the commitment, routes price and eligibility through PopRules, and orchestrates every side effect of a successful registration: the mint on the registrar, the forward wire-up on the registry, the reverse record on the reverse resolver, the immutable Store write, and any refund owed on overpayment. Acceptable input is a single DNS label of at least the minimum-length policy; shorter labels revert with `LabelTooShort`. Labels classified as governance-reserved revert with `GovernanceReserved`; a base stem held by another user reverts with `NameReserved`. On the cross-payer path the owner's recorded PoP tier must meet the label's required tier, so verified-payer-for-unverified-owner sponsorship is rejected with `OwnerStatusInsufficient` and the direct-path personhood guarantee carries over to sponsored registrations.

### DotnsPopController

Dedicated controller for the Proof-of-Personhood gateway flow. Lives behind its own UUPS proxy with its own storage and is registered on the registrar via addController alongside the commit-reveal controller. Its gated entry points are callable only under a substrate Root origin, which the controller verifies itself by reading `originIsRoot` from the revive System precompile.

Today the Pop gateway does not write a standalone user-status mapping. It materialises the PoP flow through gateway-issued labels, PoP resolver records, and reservation queue state; user tier checks for public pricing still come from the personhood precompile/context read.

The first, reserveBaseName, mints a lite-person username to a user. The gateway-facing input is a stem.suffix shape: a stem of lowercase ASCII letters, exactly one dot, then exactly two digits (for example michal.03). The stem is stricter than a DNS label, because it is the name a person chose and People Chain restricts that to letters: no digits, no hyphens, no uppercase. The same rule applies to a full-person name, which is the other name a person chooses, so `alice-bob` and `micha3l` are ordinary public names but cannot be issued as identities. How short a stem may be is not part of the shape; that is the governance-reserved band, applied by classification. The label is stored, minted and shown in that form, which is the form People Chain holds and the gateway pallet sends, so nothing is normalised at this boundary. Inputs with more than one dot, no dot, a non-digit suffix, or a suffix length other than two digits are rejected. The node is the hash of the whole string, so it can never collide with a subname built from the same characters. The stem is not limited to the 6 to 8 of the PopLite tier: a longer one is accepted, and a lite username whose stem is nine letters or more classifies as NoStatus for public pricing, so its lite status is an issuance property rather than an economic tier. A stem of five letters or fewer classifies as Reserved and is rejected on this path, which is the same governance gate that applies to short flat names. The call also persists the user's chat key on the PoP resolver and optionally enqueues a reservation for a full-person base name the user intends to claim later.

The second, registerBaseName, mints a full-person username. The label is lowercase ASCII letters only, the same rule the lite stem follows, so a hyphen or an interior digit is rejected even though both are valid in a public name. Whether the call is a claim against a prior lite reservation or a fresh standalone registration is derived from on-chain reservation state; the caller does not choose. The link argument selects the chat-key source: inherit from a prior lite label, or accept a fresh one in the payload. When inheriting, the call also writes the liteLink (full => lite) and fullClaim (lite => full) records on the PoP resolver in the same transaction so downstream consumers can resolve either direction without scanning events.

Each base label carries a head/tail-indexed reservation queue with a capacity of MAX_RESERVATION_QUEUE and a governance-configurable reservationDuration. The queue head is mirrored into PopRules on every head transition (enqueue-from-empty, expiry-driven promotion, non-expiry head removal, claim-wipes-queue), so the public commit-reveal flow sees the same cross-flow lock through its existing PopRules price check. The gateway path is symmetric: registerBaseName consults the live PopRules slot before mint and rejects with `NotHolder` when another user holds the stem, so PopRules is the single cross-flow authority in both directions. registerBaseName additionally rejects lite-classified labels (those belong on reserveBaseName) and governance-reserved labels with `InvalidBaseLabel`. Expiry advancement is permissionless: anyone can call expireReservation to garbage-collect a stale head, which is what the pallet does on its own cadence.

#### Early testnet quirk: LabelStore deployment

Pop-gateway issuances mint the name and persist its label, but LabelStore deployment is deferred for users who have not yet interacted with the protocol from their own address. The current pallet-revive runtime does not let substrate Root deploy contracts on behalf of an account it does not control, so the per-user LabelStore cannot be created at the moment the gateway writes. The controller stamps a pending-claim entry instead, and settlement writes the label into the owner's store, deploying the store on the first write. Settlement is permissionless via settlePendingClaims: the owner settles their own store, or after the claim window anyone settles a given owner's entry and pays the cost. Settlement always writes the label rather than dropping the entry, so a pending name is never stranded. When the runtime supports root-origin contract deployment, the deferred path collapses to a no-op and the issuance flow becomes one transaction end-to-end. This is a runtime limitation, not a protocol design choice.

Deferred settlement has no transfer-pricing consequence, because gateway-issued names are soulbound and cannot be transferred at all. The transfer-floor price is derived by reading the label from the sender's LabelStore, so a name held before its label is settled would have no readable label to price against; making gateway names non-transferable removes that path entirely rather than relying on settlement to close it.

### DotnsRegistrar

ERC721-backed registrar that mints ownership of label IDs (labelhashes). Minting is restricted to every address in the controllers mapping; the mapping is owner-gated through addController and removeController. Every other contract in the system that needs to check "is this address authorised to drive name state?" consults this mapping rather than keeping a parallel list, which is what lets multiple controllers coexist on the same registrar without per-contract configuration changes.

The registrar owns transferability. A name is marked soulbound at mint when the caller is the address registered under POP_CONTROLLER, so only the PoP gateway can issue a soulbound name and no other controller can lock a public one. The marker is set once and never cleared, and isSoulbound reports it. The transfer hook rejects every transfer of a soulbound name, including a move to the holder's own address and a release into escrow, so a gateway-issued name can never leave its holder's wallet. Only the mint is exempt, because the marker is set just after it.

### DotnsRegistry

Forward registry mapping node to (owner, resolver) and supporting subnode creation. When a base name is minted on the registrar, the matching controller wires the node to the new owner through this registry. Privileged node wiring defers to the same controllers mapping on the registrar, so both controllers can write without the registry tracking controllers of its own.

Subnames are created by the base-name owner. A subname carries its own (owner, resolver) and can in turn carry subnames, so the registry is the place the name hierarchy actually lives.

The registry exposes isAuthorised(node, account) as the canonical check for whether an address may manage a node: the stored owner for a subname, or the ERC-721 holder, a single-token approvee, or an operator-for-all on the registrar for a tokenised name. Sibling contracts consult this view so a single registrar-level approval delegates management across the protocol rather than each contract maintaining its own approval list.

### PopRules

PoP-aware name classification and pricing. Classification reads the label's **base length** and whether the label carries the gateway's separator, then maps to one of four tiers: NoStatus (base length 9 or more, open to anyone at the cost-model price), PopFull (base length 6-8, requires full-person verification), PopLite (a separated `stem.NN` label whose stem is 6-8 characters, gateway-issued to lite-verified users), and Reserved (base length 5 or fewer, governed by the protocol).

A lite-person label is a stem of lowercase letters, one separator, then exactly two digits (`joseph.42`), mirroring what People Chain issues; the stem's length is bounded by the bands below rather than by the shape. Base length is the label measured as written, except for a lite label, whose separator and two allocated digits are removed first. The gateway allocates those digits to distinguish people who chose the same stem, so removing them recovers what the candidate picked; no such allocation stands behind the digits in an ordinary name, so `web3` is a four-character word rather than `web` with a counter. Digits carry no protocol meaning outside the separated form: any count is accepted on an ordinary label, and none makes it PopLite. The classification determines the price and the eligibility gate the commit-reveal controller enforces.

#### Classification examples and failure modes

An ordinary label is measured as written; only a separated `stem.NN` label is shortened. The price column gives the flat deposit for a registrable example; a rejected or reserved name has no price.

| Label | Base length | Classification | Eligible public path | Price | Notes |
| --- | ---: | --- | --- | ---: | --- |
| alice | 5 | Reserved | Grant or Root only | Not sold; issued at 0 | Five characters or fewer is governance-reserved. |
| andrew.01 | 6 | PopLite | Pop gateway only | Gateway grant is free | The separated form. Its stem is six characters, and the separator with its two digits is the suffix. |
| alicebob.42 | 8 | PopLite | Pop gateway only | Gateway grant is free | Eight-character stem; the whole label is eleven characters. |
| andrewsays.01 | 10 | NoStatus | Pop gateway only | Gateway grant is free | A lite name with a long stem classifies NoStatus, so its lite status is an issuance property rather than an economic tier. |
| andrew | 6 | PopFull | PopFull user | 10 DOT | Canonical full-person base name; priced only while the short-name switch is on. |
| andrew01 | 8 | PopFull | PopFull user | 10 DOT | Measured whole. The digits are part of the name and do not make it lite. |
| andrew1 | 7 | PopFull | PopFull user | 10 DOT | Any digit count is accepted on an ordinary label. |
| web3 | 4 | Reserved | Grant or Root only | Not sold; issued at 0 | A four-character word, not `web` with a counter. |
| andrewsays | 10 | NoStatus | Anyone | 10 DOT | The amount is the flat refundable deposit. |
| andrewsays01 | 12 | NoStatus | Anyone | 10 DOT | Measured whole and still NoStatus, at the same flat deposit. |
| Andrew01 | n/a | Rejected by canonical label validator | None | n/a | Labels must be lowercase ASCII DNS labels. |
| andrew.4 | n/a | Rejected | None | n/a | A separator is legal only on a lite label, which carries exactly two digits. |
| andrew.123 | n/a | Rejected | None | n/a | Three digits is not the lite suffix. |
| alice.42 | 5 | Reserved | Pop gateway only | Not sold; not issued | A well-formed lite label whose five-letter stem is governance-reserved, so the gateway does not issue it. |
| andr3w.01 | n/a | Rejected | None | n/a | The stem is letters only, so a digit in it is not a lite label. |
| andrew-x.01 | n/a | Rejected | None | n/a | Hyphens are valid in a DNS label but not in a lite stem. |

A separated label reaches the chain only through the PoP gateway: the public path requires a single DNS label, which admits no separator. That is what reserves the dotted space to the gateway, and it is why a reader cannot take the separator alone as proof of personhood for an arbitrary string. The controller publishes `isPopIssued(label)` for that.

Tier assignment is read on every pricing call, not stored: PopRules queries the alias-accounts personhood precompile at DotnsConstants.PERSONHOOD with the dotns context (bytes32("dotns")), and translates the returned status byte into a PopStatus (0=NoStatus, 1=PopLite, 2=PopFull). Unknown tier bytes collapse to NoStatus, so a future precompile addition fails closed rather than silently being treated as a higher tier. There is no on-chain self-attestation; users obtain personhood off-chain through the People-chain ring proof and the alias-accounts pallet propagates the result via XCM.

Classification is not the same thing as effective holder context. A long label such as andrewsays is always a NoStatus-tier label by shape, but it may be held by a PopFull, PopLite, or NoStatus account. Consumers that need to know what rules apply to that live name should combine three reads: classify the label, query the registrar owner, then query the owner's dotns-context PoP status through the precompile or gateway-written state. The escrow position is the economic qualifier: if the token has an active release position with a non-zero amount, it came through the refundable NoStatus deposit path; if no such deposit exists, a verified holder can own the same long label without it being deposit-backed. In other words, andrewsays does not become a PopFull-tier label when a PopFull user owns it, but the owner can still be PopFull for transfer pricing, reverse resolution, and UI display.

Name grants are the exception path for users or organisations that need to register without satisfying the live PoP tier check. DotNS still does not accept self-attestation: the contracts only consume PoP status from the personhood precompile, and a user cannot set or prove their own status inside DotNS. Instead, `DotnsNameWhitelist` binds a specific label to a specific beneficiary, and registerReserved mints it at zero base cost, bypassing the PoP pricing gate while still using the normal commit-reveal and availability checks. Only governance issues a grant: every admin action on the whitelist requires a substrate Root dispatch, so no key can grant a name, the contract owner included. A Root dispatch can also mint a reserved name directly, without a grant. That covers the whitelist path; the registrar's controller set and the protocol registry's keys are still owner-managed, so an owner retains other routes to the same outcome.

A grant is deliberately narrow. It names one label rather than permitting any available name, it names the address the name must mint to, and it is spent by that mint, so it cannot seed a second registration. The gate reads the intended owner rather than the caller, so a relayer may submit the registration on the beneficiary's behalf; the name still lands on the beneficiary. The reserved path writes no reverse record, because the submitter is not necessarily the beneficiary and setReverseName overwrites unconditionally; the owner claims their own primary afterwards through claimReverseRecord.

A grant is a governance action. `grantName` is Root-only, so on a production network it is proposed and decided on-chain as a referendum, and on a test network it is a sudo-dispatched call. See [Name grants](./DEPLOYMENTS.md#name-grants-whitelisting) for the dispatch. 

A grant does not register a name or bypass ownership rules; it only permits the named address to register that one label without a PoP status.

PopRules also holds the cross-flow reservation table for base names, keyed by the bare stem. The PoP controller writes it on every reservation-queue head transition: it takes a bare stem directly and rejects the update when the slot is held by a different user, so the caller's local queue bookkeeping never silently diverges from the PopRules state. The commit-reveal controller has a second write path, gated on a PopLite price; since PopLite is the separated form and the public path cannot submit one, that path never fires.

Two read paths, priceWithCheck and priceWithoutCheck, are what the public flow consults. Both look the reservation up by stem, and only a separated label is shortened to reach one. So a live entry on `andrew` blocks `andrew` and `andrew.01`, while `andrew01` is a different name and is unaffected. Reservations run for 12 weeks by default.

### DotnsReverseResolver

Reverse records mapping an address to its primary name, with two write paths. The first, setReverseName, is the controller-only seeder: on the paid registration path, when the registrant asks for a default primary, registers under their own key, and has no existing primary, the commit-reveal controller calls this entry point. All three conditions matter, because this entry point overwrites unconditionally. The grant-gated reserved path never calls it: the submitter there is not necessarily the beneficiary, so writing would let a third party relabel another address. Writes through this path are restricted to the addresses registered under CONTROLLER and REGISTRAR on the protocol registry. The second, claimReverseRecord, is the self-service path open to any current name owner: the caller hands in a label and the resolver checks that registrar.ownerOf(namehash(label)) equals the caller before overwriting their reverse entry. Past ownership is never sufficient; the registrar is the single source of truth for the gate.

Reads are open but fail-closed: nameOf(address) re-validates current ownership against the registrar before returning the stored name, so an address that has transferred their primary away resolves to the empty string until they claim a new name they currently hold. The protocol still best-effort clears reverse entries on transfer (cheaper reads, no behavioural change), but the security guarantee is the fail-closed read, not the eager clear.

### DotnsContentResolver

Stores contenthash and text records per node. This is where external content links (for example IPFS hashes) and arbitrary key-value text records (for example social handles, verification metadata) live. Writes accept the node owner, any address the registry recognises as authorised for the node through isAuthorised (the ERC-721 holder, a single-token approvee, or an operator-for-all on the registrar), or an operator approved directly on this resolver; reads are open. The registry-recognised path lets a registrar-level name admin manage records without a separate grant, while the resolver-local operator is a narrower record-only delegation that confers no power over ownership or transfer. Authority is evaluated against the current owner on every write, so transferring the name reassigns write access automatically.

Choosing a delegation mechanism:

| Goal | Use | Why |
| --- | --- | --- |
| Delegate full control of one name, including the right to transfer it, automatically revoked on sale | registrar `approve(operator, tokenId)` | Single-token approval. ERC-721 clears it on every transfer, so it cannot follow the name to a buyer. |
| Delegate full control of all your names, current and future, including transferring them | registrar `setApprovalForAll(operator, true)` | The name-admin role. Persists until revoked and spans every name you hold. It grants transfer power, so grant it only to fully trusted managers; this is the approval marketplaces and escrows require. |
| Delegate record edits only, with no power over ownership or transfer | content resolver `setApprovalForAll(operator, true)` | The narrowest grant. Resolver-local and record-scoped: the operator can set text and contenthash but cannot transfer the name or change its owner. |

Revoke any grant with the inverse call (`approve(address(0), tokenId)` or `setApprovalForAll(operator, false)`). Because every write re-reads the current owner, a transfer drops all delegates the prior owner had set.

### DotnsResolver

Stores forward-resolution address records per node. This is the conventional "name to address" lookup: a client has a .dot name and wants to know the Ethereum address behind it. Writes require node ownership; reads are open.

### DotnsPopResolver

Per-node resolver for records produced by the Proof-of-Personhood flow. Three record kinds. The chat key is ECDH public-key bytes keyed by node; it is written by the PoP controller during a lite reservation and during any claim path that inherits from a prior lite entry, and is what gives verified users an on-chain discovery channel for end-to-end encrypted messaging. The lite link answers "which lite username did this full name claim from?" and is keyed by the full-person node. The full claim is the reverse direction: it answers "which full name did this lite user claim?" and is keyed by the lite labelhash. The forward and reverse links are written by the same call, so they stay in lockstep; downstream consumers that look up by lite username (Nova's pallet, for one) resolve the full name without scanning events.

Writer authorisation is dynamic: the PoP controller address is fetched from the protocol registry on every write. Rotating the PoP controller is a single set call on the protocol registry with no resolver upgrade required.

### DotnsProtocolRegistry

On-chain lookup table mapping well-known bytes32 keys (declared in DotnsConstants) to contract addresses. Every DotNS contract resolves its siblings through this registry at runtime.

Without it, each contract would store direct addresses to every contract it calls. An upgrade that changes one address would require a separate owner transaction for every contract that references it. The protocol registry reduces this to one: update the key in the registry, and every caller picks up the new address on its next call. The indirection also means a governance-driven rotation of, say, the PoP controller does not break any consumer that has already been deployed.

The registered keys include REGISTRAR, CONTROLLER, REGISTRY, REVERSE_RESOLVER, RESOLVER, CONTENT_RESOLVER, POP_RULES, STORE_FACTORY, POP_CONTROLLER, POP_RESOLVER, NAME_ESCROW, and MULTICALL3.

### Multicall3

Generic arbitrary-target batching helper using the standard Multicall3 interface. It is protocol infrastructure rather than a dotNS-specific authorisation surface: anyone can call it, and each target contract still enforces its own permissions.

For read batching, Multicall3 lets clients collect several results from the same block through one call. For write batching, callers must remember that target contracts observe Multicall3 as the caller, not the original externally owned account. That means public owner-gated dotNS writes should not be routed through Multicall3 unless the target flow explicitly supports that caller model.

### StoreFactory, LabelStore, and UserStore

Stores are the per-user storage layer. They exist because two query paths the rest of the system needs are not answerable from anywhere else: "what names has this address ever held?" cannot be served by resolvers (keyed per-node) or the registry (live ownership only, no history), and "what user-controlled records does this address publish?" has nowhere on a resolver to live since the data is not bound to any one name. Each address gets at most one of each store, forever, and the factory is the single source of truth for which store belongs to which user.

LabelStore is the protocol-managed half. The registrar and the controller set write a label entry once and the slot is permanently locked. The invariant is labels only: every per-name record category (reverse, content, forward address, chat key, lite link) goes to a dedicated resolver, and the Store stays the durable per-owner registration ledger. Because entries are append-only, transferring a name writes a fresh entry on the recipient and leaves the sender's locked entry in place, so LabelStore doubles as the address's lifetime-of-ownership ledger while the registry continues to answer for live ownership.

UserStore is the user-claimed half. The bound owner is the only writer and prior values are snapshotted into a per-key history. It exists so that user-controlled records that do not belong to a name have a home that bills the user's own contract rather than polluting a shared resolver. The labels-only invariant is preserved by the split: nothing user-written ever lands on the protocol-managed side.

### Deployments

Addresses are recorded per network in `deployments/<network>/<chain-id>.json`, and published with each release as `deployments.json`. See [DEPLOYMENTS.md](./DEPLOYMENTS.md) for how a deployment is run and [RELEASE_ARTIFACTS.md](./RELEASE_ARTIFACTS.md) for what a release contains.

### Build and test

Builds and tests are run with Foundry. Fork tests use the local Paseo Asset Hub adapter described in [DEPLOYMENTS.md](./DEPLOYMENTS.md); ordinary unit, fuzz, and invariant tests run against Foundry's in-process EVM.

## Security

Before deploying it for real use cases, you are responsible for:

- Reviewing the code yourself, we publish a reference, not a hardened production build
- Checking that the dependencies are up to date and free of known vulnerabilities
- Securing your own fork or deployment environment (keys, secrets, network configuration)
- Tracking the latest tagged release/commits for security fixes; older releases are not backported (exceptions might apply)

For Parity's security disclosure process, and Bug Bounty program, feel free to visit:  https://parity.io/bug-bounty

## Known limitations

The protocol carries a handful of constraints worth knowing before deploying or building against it. Most stem from the current pallet-revive runtime rather than from protocol design, and collapse to a no-op once the runtime gains the corresponding capability. [KNOWN_ISSUES.md](./KNOWN_ISSUES.md) is the consolidated reference; each issue is also described in full where the relevant contract is documented below.

- **Deferred LabelStore deployment** (runtime). See [DotnsPopController](#early-testnet-quirk-labelstore-deployment).
- **No standalone user-status mapping** (current implementation). See [DotnsPopController](#dotnspopcontroller).

## License

Licensed under the MIT License. See [LICENSE](./LICENSE). External interface definitions under `contracts/external/` retain their upstream licences (the SPDX header in each file is authoritative). Security policy and disclosure: see [SECURITY.md](./SECURITY.md).
