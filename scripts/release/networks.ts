/**
 * Maps a `deployments/<dir>` directory name to the consumer-facing network
 * key + display name. Networks may be registered ahead of their first
 * deployment; the codegen in `pack.ts` skips entries whose deployment file
 * is missing, so a new network lights up automatically once its
 * `deployments/<dir>/<chainId>.json` lands.
 */
export const NETWORKS = {
  "paseo-assethub": { key: "paseo-previewnet", display: "Paseo Asset Hub Previewnet" },
  "passethub-testnet": { key: "paseo-v2", display: "Paseo Asset Hub V2" },
} as const satisfies Record<string, { key: string; display: string }>;

export type NetworkDirName = keyof typeof NETWORKS;
