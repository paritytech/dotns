## Description
## Type

- [ ] Bug fix
- [ ] Feature
- [ ] Breaking change
- [ ] Documentation
- [ ] Chore
- [ ] Refactor
- [ ] Security

## Scope

- [ ] Registration
- [ ] Resolver
- [ ] Store
- [ ] Proof of Personhood
- [ ] Deployment scripts
- [ ] Tests

## Related Issues

## Fixes

## Checklist

### Code

- [ ] Follows project style
- [ ] `forge build` passes
- [ ] `forge test` passes
- [ ] No new compiler warnings

### Testing

- [ ] New tests added for changed behavior
- [ ] Fuzz tests added where applicable
- [ ] Invariant tests verified

### Security

- [ ] No new `selfdestruct` or `delegatecall`
- [ ] Access control reviewed
- [ ] No storage layout conflicts (for upgradeable contracts)

### Documentation

- [ ] NatSpec updated on changed interfaces
- [ ] README updated if needed

### Breaking Changes

- [ ] No breaking changes
- [ ] Breaking changes documented below

**Breaking changes:**

<!-- Whatever you write here is copied into the release notes under "Breaking changes".
Say what stops working and what integrators need to change. Leave it empty if nothing breaks. -->

## How to test

```bash
forge test --mt <testName>
```

## Notes