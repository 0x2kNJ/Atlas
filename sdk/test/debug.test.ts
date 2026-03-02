import { it, expect } from "vitest";
import { hashTypedData, encodeAbiParameters, keccak256 } from "viem";
import { ATLAS_TYPES, kernelDomain } from "../src/eip712.js";
import { SCOPE, ZERO_HASH } from "../src/types.js";

const kernelAddr  = "0xe7f1725e7734ce288f8367e1bb143e90bb3f0512" as `0x${string}`;
const adapterAddr = "0x9fe46736679d2d9a65f0992f2272de9f3c7fa6e0" as `0x${string}`;
const usdcAddr    = "0xcf7ed3acca5a467e9e704c703e8d87f634fb0fc9" as `0x${string}`;
const wethAddr    = "0xdc64a140aa3e981100a9beca4e685f962f0cf6c9" as `0x${string}`;

const cap = {
  issuer:   "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as `0x${string}`,
  grantee:  "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" as `0x${string}`,
  scope:    SCOPE.VAULT_SPEND,
  expiry:   2_000_000_000n,
  nonce:    keccak256(encodeAbiParameters([{ type: "uint256" }], [1000n])),
  constraints: {
    maxSpendPerPeriod: 5_000_000_000n,
    periodDuration:    86400n,
    minReturnBps:      9500n,
    allowedAdapters:   [adapterAddr],
    allowedTokensIn:   [usdcAddr],
    allowedTokensOut:  [wethAddr],
  },
  parentCapabilityHash: ZERO_HASH,
  delegationDepth: 0,
};

it("hashTypedData with real addresses works", () => {
  console.log("cap.constraints.allowedAdapters:", cap.constraints.allowedAdapters);
  console.log("ATLAS_TYPES.Capability:", JSON.stringify(ATLAS_TYPES.Capability));
  
  const result = hashTypedData({
    domain:      kernelDomain(kernelAddr, 31337),
    types:       ATLAS_TYPES,
    primaryType: "Capability",
    message:     cap,
  });
  console.log("SUCCESS:", result);
  expect(result).toMatch(/^0x[0-9a-f]{64}$/i);
});
