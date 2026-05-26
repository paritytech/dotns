/**
 * Canonical list of DotNS contracts whose ABIs are extracted from `out/` at
 * release time. Consumed by the GH Release ABI zip step (via list-contracts.ts)
 * and by `packages/abi/wagmi.config.ts` for `as const` ABI codegen.
 */
export const CONTRACTS = [
  "StoreFactory",
  "LabelStore",
  "UserStore",
  "DotnsRegistrar",
  "DotnsReverseResolver",
  "DotnsRegistry",
  "DotnsContentResolver",
  "DotnsResolver",
  "PopRules",
  "DotnsRegistrarController",
  "DotnsProtocolRegistry",
  "DotnsNameEscrow",
  "DotnsPopController",
  "DotnsPopResolver",
  "DotnsRoleManager",
  "RootGatewayDispatcher",
  "IStoreFactory",
  "ILabelStore",
  "IUserStore",
  "IDotnsRegistrar",
  "IDotnsRegistrarController",
  "IDotnsRegistry",
  "IDotnsReverseResolver",
  "IDotnsContentResolver",
  "IDotnsResolver",
  "IPopRules",
  "IDotnsProtocolRegistry",
  "IDotnsNameEscrow",
  "IDotnsPopController",
  "IDotnsPopResolver",
  "IDotnsController",
  "IDotnsRoleManager",
] as const;

export type ContractName = (typeof CONTRACTS)[number];
