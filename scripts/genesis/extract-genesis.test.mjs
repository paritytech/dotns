#!/usr/bin/env node --test

/**
 * Unit tests for the DotNS genesis extractor.
 *
 * The regression these guard against shipped once: the extractor followed only
 * the EIP-1967 proxy slot, so the two store implementations behind the
 * UpgradeableBeacons were left out of dotns-genesis.json. previewnet booted
 * with beacons pointing at empty addresses and every store creation reverted
 * with ERC1967InvalidImplementation.
 *
 * Run: node --test scripts/genesis/extract-genesis.test.mjs
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  EIP1967_IMPL_SLOT,
  addressFromWord,
  buildGenesis,
  collectAccounts,
  findMissingImplementations,
  BEACON_IMPL_SLOT,
} from "./extract-genesis.mjs";

// Fixture: a miniature anvil dump shaped like the real DotNS deploy

const REGISTRY = "0x00000000000000000000000000000000000000a1";
const REGISTRY_IMPL = "0x00000000000000000000000000000000000000a2";
const BEACON = "0x00000000000000000000000000000000000000b1";
const STORE_IMPL = "0x00000000000000000000000000000000000000b2";
const STORE_IMPL_DEP = "0x00000000000000000000000000000000000000b3";
const FACTORY = "0x00000000000000000000000000000000000000c1";
const OWNER_EOA = "0x00000000000000000000000000000000000000ee";
const UNRELATED = "0x00000000000000000000000000000000000000ff";

const slot = (n) => "0x" + n.toString(16).padStart(64, "0");
const word = (addr) => "0x" + addr.replace(/^0x/, "").padStart(64, "0");

function fixture() {
  return {
    accounts: {
      [REGISTRY]: {
        balance: "0x0",
        nonce: 1,
        code: "0xfe01",
        storage: {
          // UUPS proxy pointing at its implementation
          [EIP1967_IMPL_SLOT]: word(REGISTRY_IMPL),
          // an owner: an address, but an EOA, so not a reference to follow
          [slot(0)]: word(OWNER_EOA),
          // a hash-shaped word that must not be mistaken for a pointer
          [slot(1)]:
            "0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300",
          // a pointer to an address that has no code — nothing to extract
          [slot(2)]: word("0x00000000000000000000000000000000deadbeef"),
        },
      },
      [REGISTRY_IMPL]: { balance: "0x0", nonce: 1, code: "0xfe02", storage: {} },
      [BEACON]: {
        balance: "0x0",
        nonce: 1,
        code: "0xfe03",
        storage: {
          // UpgradeableBeacon: owner in slot 0, implementation in slot 1 —
          // a plain slot, not the EIP-1967 one
          [slot(0)]: word(FACTORY),
          [slot(1)]: word(STORE_IMPL),
        },
      },
      [STORE_IMPL]: {
        balance: "0x0",
        nonce: 1,
        code: "0xfe04",
        // unpadded slot and value, as anvil writes them
        storage: { "0x0": "0xb3" },
      },
      [STORE_IMPL_DEP]: { balance: "0x0", nonce: 1, code: "0xfe05", storage: {} },
      [FACTORY]: {
        balance: "0x2a",
        nonce: 5,
        code: "0xfe06",
        storage: { [slot(0)]: word(OWNER_EOA) },
      },
      [OWNER_EOA]: { balance: "0xde0b6b3a7640000", nonce: 3, code: "0x" },
      [UNRELATED]: { balance: "0x0", nonce: 1, code: "0xfe07", storage: {} },
    },
  };
}

const MANIFEST = {
  DotnsRegistry: REGISTRY,
  StoreBeacon: BEACON,
  StoreFactory: FACTORY,
  _seed: "0x0000000000000000000000000000000000000000",
};

const addressesOf = (genesis) => genesis.accounts.map((a) => a.address).sort();

// addressFromWord

test("addressFromWord reads the low 20 bytes, including a packed pointer", () => {
  assert.equal(addressFromWord(word(STORE_IMPL)), STORE_IMPL);
  assert.equal(
    addressFromWord("0xb2"),
    "0x" + "0".repeat(38) + "b2",
    "anvil writes words unpadded, so a short word is still an address"
  );
  assert.equal(
    addressFromWord(
      "0x000000000000000000000001" + STORE_IMPL.slice(2)
    ),
    STORE_IMPL,
    "a pointer Solidity packed beside a bool in the same slot has a dirty high " +
      "prefix; requiring zero there silently drops the implementation it points at"
  );
  assert.equal(addressFromWord(word("0x" + "0".repeat(40))), null, "zero address");
  assert.equal(addressFromWord(undefined), null);
});

test("a hash-shaped word yields a candidate that is dropped for having no code", () => {
  const hash =
    "0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300";
  // addressFromWord is deliberately permissive, so the word does resolve...
  assert.equal(addressFromWord(hash), "0x" + hash.slice(26));

  // ...and referencedContracts is what discards it, because nothing lives there.
  const state = fixture();
  state.accounts[REGISTRY].storage[slot(9)] = hash;
  const genesis = buildGenesis(state, MANIFEST);
  assert.ok(
    !addressesOf(genesis).includes("0x" + hash.slice(26)),
    "a word that is really a hash must not become a genesis account"
  );
});

// Discovery

test("beacon implementations are extracted (the previewnet regression)", () => {
  const genesis = buildGenesis(fixture(), MANIFEST);
  const addresses = addressesOf(genesis);

  assert.ok(
    addresses.includes(STORE_IMPL),
    "the implementation behind an UpgradeableBeacon must be in the genesis — " +
      "without it every store creation reverts with ERC1967InvalidImplementation"
  );
});

test("collectAccounts names what it discovers and how it got there", () => {
  const found = collectAccounts(fixture().accounts, Object.entries(MANIFEST));

  assert.equal(found.get(REGISTRY), "DotnsRegistry");
  assert.equal(found.get(REGISTRY_IMPL), "DotnsRegistry_Implementation");
  assert.equal(found.get(STORE_IMPL), "StoreBeacon_Ref@slot1");
  assert.equal(found.get(STORE_IMPL_DEP), "StoreBeacon_Ref@slot1_Ref@slot0");
});

test("extraction reaches transitively and stops at what is actually referenced", () => {
  const genesis = buildGenesis(fixture(), MANIFEST);
  const addresses = addressesOf(genesis);

  assert.deepEqual(
    addresses,
    [REGISTRY, REGISTRY_IMPL, BEACON, STORE_IMPL, STORE_IMPL_DEP, FACTORY].sort(),
    "manifest entries plus every contract reachable from them"
  );
  assert.ok(!addresses.includes(OWNER_EOA), "EOAs are not contracts");
  assert.ok(
    !addresses.includes(UNRELATED),
    "contracts nothing points at stay out of the genesis"
  );
});

test("the _seed sentinel is not treated as a contract", () => {
  const genesis = buildGenesis(fixture(), MANIFEST);
  assert.ok(
    !genesis.accounts.some(
      (a) => a.address === "0x0000000000000000000000000000000000000000"
    )
  );
});

test("a manifest contract missing from the state dump is fatal", () => {
  // The manifest is the only source of truth for what consumers expect to find.
  // Skipping produced a genesis that looked fine and reverted at the first call.
  assert.throws(
    () =>
      buildGenesis(fixture(), {
        ...MANIFEST,
        Ghost: "0x0000000000000000000000000000000000009999",
      }),
    /Ghost .* absent from the state dump/
  );
});

test("a manifest contract present but codeless is fatal", () => {
  const state = fixture();
  const bare = "0x0000000000000000000000000000000000008888";
  state.accounts[bare] = { balance: "0x0", nonce: 0, code: "0x", storage: {} };
  assert.throws(
    () => buildGenesis(state, { ...MANIFEST, Bare: bare }),
    /Bare .* carries no code/
  );
});

test("underscore-prefixed manifest keys are metadata, not contracts", () => {
  // _seed today, _deployedFrom once dotns-releases#12 lands.
  const genesis = buildGenesis(fixture(), {
    ...MANIFEST,
    _seed: "0x0000000000000000000000000000000000000000",
    _deployedFrom: "some-tag",
  });
  assert.equal(genesis.accounts.length, 6);
});

// Output shape

test("accounts carry padded storage, hex balance and nonce", () => {
  const genesis = buildGenesis(fixture(), MANIFEST);

  const factory = genesis.accounts.find((a) => a.address === FACTORY);
  assert.equal(
    factory.balance,
    "0x2a",
    "balance is sp_core::U256, whose impl_serde serde impl is hex — a decimal " +
      "string is not rejected but reinterpreted, so 42 would be read as 0x42"
  );
  assert.equal(factory.nonce, 5);
  assert.equal(factory.code, "0xfe06");

  const storeImpl = genesis.accounts.find((a) => a.address === STORE_IMPL);
  assert.deepEqual(
    storeImpl.storage,
    { [slot(0)]: word("0xb3") },
    "anvil's unpadded slots and values are padded to 32 bytes"
  );
});

// The proxy/implementation guard

test("findMissingImplementations catches a proxy whose impl never deployed", () => {
  // The blind spot this exists for: referencedContracts only follows a pointer whose
  // target already has code, so an implementation that failed to deploy is dropped
  // silently and nothing downstream would notice.
  // in no fixture
  const ghost = "0x00000000000000000000000000000000000000dd";
  const accounts = [
    {
      address: REGISTRY,
      balance: "0x0",
      nonce: 1,
      code: "0xfe01",
      storage: { [EIP1967_IMPL_SLOT]: word(ghost) },
    },
  ];

  assert.deepEqual(findMissingImplementations(accounts), [
    { proxy: REGISTRY, impl: ghost },
  ]);
});

test("findMissingImplementations passes on a complete genesis", () => {
  const genesis = buildGenesis(fixture(), MANIFEST);
  assert.deepEqual(findMissingImplementations(genesis.accounts), []);
});

test("buildGenesis throws when a proxy implementation is absent", () => {
  const state = fixture();
  // Point the registry proxy at an address that carries no code, so the collector
  // never walks to it and only the independent check can notice.
  state.accounts[REGISTRY].storage[EIP1967_IMPL_SLOT] = word(
    "0x00000000000000000000000000000000000000dd"
  );
  assert.throws(
    () => buildGenesis(state, MANIFEST),
    /proxy\/proxies with no implementation/
  );
});

test("a beacon whose implementation is absent is fatal", () => {
  // The previewnet regression was a beacon, not an EIP-1967 proxy. A beacon keeps its
  // implementation in slot 1, so a guard that reads only the EIP-1967 slot cannot see this.
  const state = fixture();
  delete state.accounts[STORE_IMPL];
  assert.throws(() => buildGenesis(state, MANIFEST), /no implementation/);
});

test("an EOA pointer in slot 1 of a non-beacon is not an error", () => {
  // Slot 1 holds an ordinary field on anything that is not a beacon, and a pointer-shaped
  // word there is usually an owner or operator. Flagging those would break every build.
  const accounts = [
    {
      address: FACTORY,
      balance: "0x0",
      nonce: 1,
      code: "0xfe06",
      storage: { [BEACON_IMPL_SLOT]: word(OWNER_EOA) },
    },
  ];
  assert.deepEqual(findMissingImplementations(accounts), []);
  assert.deepEqual(
    findMissingImplementations(accounts, new Set([FACTORY])),
    [{ proxy: FACTORY, impl: OWNER_EOA }],
    "named as a beacon, the same word IS a missing implementation"
  );
});

test("the artifact records its TLD, so a rename cannot hide it", () => {
  const withTld = buildGenesis(fixture(), MANIFEST, () => {}, "test");
  assert.equal(withTld.tld, "test");
  assert.ok(Array.isArray(withTld.accounts));

  const without = buildGenesis(fixture(), MANIFEST);
  assert.ok(!("tld" in without), "omitted rather than null when not supplied");
});
