/**
 * Loads compiled Foundry artifacts for integration tests.
 * Artifacts live in <workspace>/out/<Contract>.sol/<Contract>.json.
 */

import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import type { Abi } from "viem";

const WORKSPACE_ROOT = resolve(import.meta.dirname, "../../../");

function loadArtifact(contractDir: string, contractName: string): { abi: Abi; bytecode: `0x${string}` } {
  const path = join(WORKSPACE_ROOT, "out", contractDir, `${contractName}.json`);
  const raw = JSON.parse(readFileSync(path, "utf-8"));
  return {
    abi:      raw.abi as Abi,
    bytecode: raw.bytecode.object as `0x${string}`,
  };
}

export const ARTIFACTS = {
  SingletonVault:  () => loadArtifact("SingletonVault.sol",  "SingletonVault"),
  CapabilityKernel:() => loadArtifact("CapabilityKernel.sol","CapabilityKernel"),
  EnvelopeRegistry:() => loadArtifact("EnvelopeRegistry.sol","EnvelopeRegistry"),
  MockAdapter:     () => loadArtifact("MockAdapter.sol",     "MockAdapter"),
  MockERC20:       () => loadArtifact("MockERC20.sol",       "MockERC20"),
} as const;
