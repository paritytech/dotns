import { defineConfig } from "@wagmi/cli";
import { foundry } from "@wagmi/cli/plugins";
import { CONTRACTS } from "../../scripts/release/contracts.ts";

export default defineConfig({
  out: "src/generated.ts",
  plugins: [
    foundry({
      project: "../..",
      include: CONTRACTS.map((name) => `${name}.sol/${name}.json`),
    }),
  ],
});
