# PoP Rules

Pricing and access control for DotNS names based on Proof of Personhood status.

## Why

Short names are scarce. Without some mechanism, they get scooped up by speculators or bots. PoP verification lets us allocate names more fairly;  if you can prove you're a unique human, you get access to shorter names with or without characters for Pop full and light.

## How it works

Names are classified by length and suffix:

| Base Length | Suffix | Requirement |
|-------------|--------|-------------|
| ≤ 5 chars | any | Reserved (governance) |
| 6-8 chars | none | PopFull |
| 6-8 chars | 2 digits | PopLite |
| ≥ 9 chars | none | PopFull |
| ≥ 9 chars | 2 digits | NoStatus |

"Base length" means the name without trailing digits. So `alice01` has base length 5 (`alice`).

The 2-digit suffix thing is a compromise. It lets unverified users participate while keeping base names for verified humans.

## Reservations

When someone with PopLite registers `alice01`, they get a 12-week reservation on the base name `alice`. This prevents someone else from sniping `alice02` before the original registrant can upgrade to PopFull.

## Pricing

Verified users pay nothing. Unverified users pay based on length:

- < 9 chars: 0 (can't register anyway)
- 9-14 chars: `starting_price * (15 - length)`
- ≥ 15 chars: `starting_price / 2`

This isn't about revenue. It's spam prevention.

## Contract Interface

```rust
// Check what tier a name requires
fn classify_name(name: String) -> Result<Classification, PopRulesError>

// Get price + metadata (reverts on reserved names)
fn price_with_check(name: String, user: H160) -> Result<PriceWithMeta, PopRulesError>

// Get price + metadata (doesn't revert, just marks as reserved)
fn price_without_check(name: String, user: H160) -> Result<PriceWithMeta, PopRulesError>

// Set your PoP status (temporary until precompile exists)
fn set_user_pop_status(status: PopStatus)

// Reserve a base name (registry only)
fn reserve_base_name(name: String, user: H160) -> Result<(), PopRulesError>
```

## Building

```bash
cd contracts/pop-rules
pop build
```

## Testing

```bash
pop test 
```

## Upgradeability

Contract uses `set_code_hash` for upgrades. Storage layout must stay compatible - don't reorder fields, don't change types, only append new fields at the end.

## License

MIT