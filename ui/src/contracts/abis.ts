export const ERC20_ABI = [
  { name: "balanceOf",  type: "function", stateMutability: "view",        inputs: [{ name: "account", type: "address" }],                                          outputs: [{ type: "uint256" }] },
  { name: "allowance",  type: "function", stateMutability: "view",        inputs: [{ name: "owner",   type: "address" }, { name: "spender", type: "address" }],    outputs: [{ type: "uint256" }] },
  { name: "approve",    type: "function", stateMutability: "nonpayable",   inputs: [{ name: "spender", type: "address" }, { name: "amount",  type: "uint256" }],    outputs: [{ type: "bool" }] },
  { name: "mint",       type: "function", stateMutability: "nonpayable",   inputs: [{ name: "to",      type: "address" }, { name: "amount",  type: "uint256" }],    outputs: [] },
  { name: "decimals",   type: "function", stateMutability: "view",        inputs: [],                                                                              outputs: [{ type: "uint8" }] },
] as const;

export const CLAWLOAN_POOL_ABI = [
  { name: "borrow",            type: "function", stateMutability: "nonpayable", inputs: [{ name: "botId", type: "uint256" }, { name: "amount", type: "uint256" }],      outputs: [] },
  { name: "repay",             type: "function", stateMutability: "nonpayable", inputs: [{ name: "botId", type: "uint256" }, { name: "amount", type: "uint256" }],      outputs: [] },
  { name: "getDebt",           type: "function", stateMutability: "view",       inputs: [{ name: "botId", type: "uint256" }],                                           outputs: [{ type: "uint256" }] },
  { name: "isLoanOutstanding", type: "function", stateMutability: "view",       inputs: [{ name: "botId", type: "uint256" }],                                           outputs: [{ type: "bool" }] },
  { name: "accrueInterest",    type: "function", stateMutability: "nonpayable", inputs: [{ name: "botId", type: "uint256" }, { name: "interestAmount", type: "uint256" }], outputs: [] },
  {
    name: "Borrowed", type: "event",
    inputs: [{ name: "botId", type: "uint256", indexed: true }, { name: "borrower", type: "address", indexed: true }, { name: "amount", type: "uint256", indexed: false }],
  },
  {
    name: "Repaid", type: "event",
    inputs: [{ name: "botId", type: "uint256", indexed: true }, { name: "repayer", type: "address", indexed: true }, { name: "amount", type: "uint256", indexed: false }],
  },
] as const;

export const VAULT_ABI = [
  { name: "deposit",        type: "function", stateMutability: "nonpayable", inputs: [{ name: "asset", type: "address" }, { name: "amount", type: "uint256" }, { name: "salt", type: "bytes32" }], outputs: [{ name: "positionHash", type: "bytes32" }] },
  { name: "withdraw",       type: "function", stateMutability: "nonpayable", inputs: [{ name: "position", type: "tuple", components: [{ name: "owner", type: "address" }, { name: "asset", type: "address" }, { name: "amount", type: "uint256" }, { name: "salt", type: "bytes32" }] }, { name: "to", type: "address" }], outputs: [] },
  { name: "positionExists", type: "function", stateMutability: "view",       inputs: [{ name: "positionHash", type: "bytes32" }],                                                                   outputs: [{ type: "bool" }] },
  { name: "isEncumbered",   type: "function", stateMutability: "view",       inputs: [{ name: "positionHash", type: "bytes32" }],                                                                   outputs: [{ type: "bool" }] },
  // vault custom errors — included so simulateContract decodes them
  { name: "PositionAlreadyExists", type: "error", inputs: [] },
  { name: "TokenNotAllowlisted",   type: "error", inputs: [] },
  { name: "ZeroAmount",            type: "error", inputs: [] },
  { name: "ZeroAddress",           type: "error", inputs: [] },
  { name: "PositionIsEncumbered",  type: "error", inputs: [] },
] as const;

export const KERNEL_ABI = [
  {
    name: "executeIntent", type: "function", stateMutability: "nonpayable",
    inputs: [
      { name: "position",   type: "tuple",  components: [{ name: "owner", type: "address" }, { name: "asset", type: "address" }, { name: "amount", type: "uint256" }, { name: "salt", type: "bytes32" }] },
      { name: "capability", type: "tuple",  components: [{ name: "issuer", type: "address" }, { name: "grantee", type: "address" }, { name: "scope", type: "bytes32" }, { name: "expiry", type: "uint256" }, { name: "nonce", type: "bytes32" }, { name: "constraints", type: "tuple", components: [{ name: "maxSpendPerPeriod", type: "uint256" }, { name: "periodDuration", type: "uint256" }, { name: "minReturnBps", type: "uint256" }, { name: "allowedAdapters", type: "address[]" }, { name: "allowedTokensIn", type: "address[]" }, { name: "allowedTokensOut", type: "address[]" }] }, { name: "parentCapabilityHash", type: "bytes32" }, { name: "delegationDepth", type: "uint8" }] },
      { name: "intent",     type: "tuple",  components: [{ name: "positionCommitment", type: "bytes32" }, { name: "capabilityHash", type: "bytes32" }, { name: "adapter", type: "address" }, { name: "adapterData", type: "bytes" }, { name: "minReturn", type: "uint256" }, { name: "deadline", type: "uint256" }, { name: "nonce", type: "bytes32" }, { name: "outputToken", type: "address" }, { name: "returnTo", type: "address" }, { name: "submitter", type: "address" }, { name: "solverFeeBps", type: "uint16" }] },
      { name: "capSig",     type: "bytes" },
      { name: "intentSig",  type: "bytes" },
    ],
    outputs: [],
  },
] as const;

export const REGISTRY_ABI = [
  {
    name: "register", type: "function", stateMutability: "nonpayable",
    inputs: [
      { name: "envelope",    type: "tuple", components: [{ name: "positionCommitment", type: "bytes32" }, { name: "conditionsHash", type: "bytes32" }, { name: "intentCommitment", type: "bytes32" }, { name: "capabilityHash", type: "bytes32" }, { name: "expiry", type: "uint256" }, { name: "keeperRewardBps", type: "uint16" }, { name: "minKeeperRewardWei", type: "uint128" }] },
      { name: "manageCap",   type: "tuple", components: [{ name: "issuer", type: "address" }, { name: "grantee", type: "address" }, { name: "scope", type: "bytes32" }, { name: "expiry", type: "uint256" }, { name: "nonce", type: "bytes32" }, { name: "constraints", type: "tuple", components: [{ name: "maxSpendPerPeriod", type: "uint256" }, { name: "periodDuration", type: "uint256" }, { name: "minReturnBps", type: "uint256" }, { name: "allowedAdapters", type: "address[]" }, { name: "allowedTokensIn", type: "address[]" }, { name: "allowedTokensOut", type: "address[]" }] }, { name: "parentCapabilityHash", type: "bytes32" }, { name: "delegationDepth", type: "uint8" }] },
      { name: "manageCapSig", type: "bytes" },
      { name: "position",    type: "tuple", components: [{ name: "owner", type: "address" }, { name: "asset", type: "address" }, { name: "amount", type: "uint256" }, { name: "salt", type: "bytes32" }] },
    ],
    outputs: [{ name: "envelopeHash", type: "bytes32" }],
  },
  {
    name: "trigger", type: "function", stateMutability: "nonpayable",
    inputs: [
      { name: "envelopeHash", type: "bytes32" },
      { name: "conditions",   type: "tuple", components: [{ name: "priceOracle", type: "address" }, { name: "baseToken", type: "address" }, { name: "quoteToken", type: "address" }, { name: "triggerPrice", type: "uint256" }, { name: "op", type: "uint8" }, { name: "secondaryOracle", type: "address" }, { name: "secondaryTriggerPrice", type: "uint256" }, { name: "secondaryOp", type: "uint8" }, { name: "logicOp", type: "uint8" }] },
      { name: "position",     type: "tuple", components: [{ name: "owner", type: "address" }, { name: "asset", type: "address" }, { name: "amount", type: "uint256" }, { name: "salt", type: "bytes32" }] },
      { name: "intent",       type: "tuple", components: [{ name: "positionCommitment", type: "bytes32" }, { name: "capabilityHash", type: "bytes32" }, { name: "adapter", type: "address" }, { name: "adapterData", type: "bytes" }, { name: "minReturn", type: "uint256" }, { name: "deadline", type: "uint256" }, { name: "nonce", type: "bytes32" }, { name: "outputToken", type: "address" }, { name: "returnTo", type: "address" }, { name: "submitter", type: "address" }, { name: "solverFeeBps", type: "uint16" }] },
      { name: "spendCap",     type: "tuple", components: [{ name: "issuer", type: "address" }, { name: "grantee", type: "address" }, { name: "scope", type: "bytes32" }, { name: "expiry", type: "uint256" }, { name: "nonce", type: "bytes32" }, { name: "constraints", type: "tuple", components: [{ name: "maxSpendPerPeriod", type: "uint256" }, { name: "periodDuration", type: "uint256" }, { name: "minReturnBps", type: "uint256" }, { name: "allowedAdapters", type: "address[]" }, { name: "allowedTokensIn", type: "address[]" }, { name: "allowedTokensOut", type: "address[]" }] }, { name: "parentCapabilityHash", type: "bytes32" }, { name: "delegationDepth", type: "uint8" }] },
      { name: "capSig",       type: "bytes" },
      { name: "intentSig",    type: "bytes" },
    ],
    outputs: [],
  },
  {
    name: "cancel", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "envelopeHash", type: "bytes32" }],
    outputs: [],
  },
  {
    name: "isActive", type: "function", stateMutability: "view",
    inputs: [{ name: "envelopeHash", type: "bytes32" }],
    outputs: [{ type: "bool" }],
  },
  {
    // EnvelopeRecord: envelope (nested tuple) + issuer + status
    name: "envelopes", type: "function", stateMutability: "view",
    inputs: [{ name: "envelopeHash", type: "bytes32" }],
    outputs: [
      {
        name: "envelope", type: "tuple",
        components: [
          { name: "positionCommitment", type: "bytes32" },
          { name: "conditionsHash",     type: "bytes32" },
          { name: "intentCommitment",   type: "bytes32" },
          { name: "capabilityHash",     type: "bytes32" },
          { name: "expiry",             type: "uint256" },
          { name: "keeperRewardBps",    type: "uint16"  },
          { name: "minKeeperRewardWei", type: "uint128" },
        ],
      },
      { name: "issuer",  type: "address" },
      { name: "status",  type: "uint8"   },
    ],
  },
  // Registry + kernel errors so simulateContract on trigger() decodes them all
  { name: "EnvelopeNotFound",            type: "error", inputs: [] },
  { name: "EnvelopeNotActive",           type: "error", inputs: [] },
  { name: "ConditionsMismatch",          type: "error", inputs: [] },
  { name: "IntentMismatch",              type: "error", inputs: [] },
  { name: "ConditionNotMet",             type: "error", inputs: [] },
  { name: "OracleStale",                 type: "error", inputs: [] },
  { name: "OracleInvalidAnswer",         type: "error", inputs: [] },
  { name: "KeeperRewardTooHigh",         type: "error", inputs: [] },
  { name: "NotIssuer",                   type: "error", inputs: [] },
  { name: "EnvelopeAlreadyExists",       type: "error", inputs: [] },
  { name: "IntentExpired",               type: "error", inputs: [] },
  { name: "CapabilityExpired",           type: "error", inputs: [] },
  { name: "InvalidCapabilitySig",        type: "error", inputs: [] },
  { name: "InvalidIntentSig",            type: "error", inputs: [] },
  { name: "SolverNotApproved",           type: "error", inputs: [] },
  { name: "CapabilityHashMismatch",      type: "error", inputs: [] },
  { name: "CommitmentMismatch",          type: "error", inputs: [] },
  { name: "OwnerMismatch",               type: "error", inputs: [] },
  { name: "NullifierSpent",              type: "error", inputs: [] },
  { name: "PositionEncumberedError",     type: "error", inputs: [] },
  { name: "AdapterNotRegistered",        type: "error", inputs: [] },
  { name: "WrongScope",                  type: "error", inputs: [] },
  { name: "UnauthorizedSubmitter",       type: "error", inputs: [] },
  { name: "SolverFeeTooHigh",            type: "error", inputs: [] },
  { name: "InsufficientOutput",          type: "error", inputs: [] },
] as const;

export const CREDIT_VERIFIER_ABI = [
  { name: "getCreditTier", type: "function", stateMutability: "view", inputs: [{ name: "capabilityHash", type: "bytes32" }], outputs: [{ type: "uint8" }] },
  { name: "getMaxBorrow",  type: "function", stateMutability: "view", inputs: [{ name: "capabilityHash", type: "bytes32" }], outputs: [{ type: "uint256" }] },
  {
    name: "submitProof", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "capabilityHash", type: "bytes32" }, { name: "n", type: "uint256" }, { name: "adapterFilter", type: "address" }, { name: "minReturnBps", type: "uint256" }, { name: "proof", type: "bytes" }],
    outputs: [],
  },
] as const;

export const ACCUMULATOR_ABI = [
  { name: "receiptCount",             type: "function", stateMutability: "view", inputs: [{ name: "capabilityHash", type: "bytes32" }],                                                                  outputs: [{ type: "uint256" }] },
  { name: "getReceiptHashes",         type: "function", stateMutability: "view", inputs: [{ name: "capabilityHash", type: "bytes32" }],                                                                  outputs: [{ type: "bytes32[]" }] },
  { name: "getNullifiers",            type: "function", stateMutability: "view", inputs: [{ name: "capabilityHash", type: "bytes32" }],                                                                  outputs: [{ type: "bytes32[]" }] },
  { name: "adapterReceiptCount",      type: "function", stateMutability: "view", inputs: [{ name: "capabilityHash", type: "bytes32" }, { name: "adapter", type: "address" }],                           outputs: [{ type: "uint256" }] },
  { name: "rootAtIndex",              type: "function", stateMutability: "view", inputs: [{ name: "capabilityHash", type: "bytes32" }, { name: "index", type: "uint256" }],                              outputs: [{ type: "bytes32" }] },
  { name: "getAdapterReceiptHashes",  type: "function", stateMutability: "view", inputs: [{ name: "capabilityHash", type: "bytes32" }, { name: "adapter", type: "address" }],                           outputs: [{ type: "bytes32[]" }] },
  { name: "getAdapterNullifiers",     type: "function", stateMutability: "view", inputs: [{ name: "capabilityHash", type: "bytes32" }, { name: "adapter", type: "address" }],                           outputs: [{ type: "bytes32[]" }] },
  { name: "adapterRootAtIndex",       type: "function", stateMutability: "view", inputs: [{ name: "capabilityHash", type: "bytes32" }, { name: "adapter", type: "address" }, { name: "index", type: "uint256" }], outputs: [{ type: "bytes32" }] },
  { name: "rollingRoot",              type: "function", stateMutability: "view", inputs: [{ name: "capabilityHash", type: "bytes32" }],                                                                  outputs: [{ type: "bytes32" }] },
] as const;

// ─── Phase 2: DirectTransferAdapter ───────────────────────────────────────────
export const DIRECT_TRANSFER_ADAPTER_ABI = [
  { name: "name",     type: "function", stateMutability: "pure",        inputs: [],                                                                                                                                                                             outputs: [{ type: "string" }] },
  { name: "target",   type: "function", stateMutability: "pure",        inputs: [],                                                                                                                                                                             outputs: [{ type: "address" }] },
  { name: "quote",    type: "function", stateMutability: "pure",        inputs: [{ name: "tokenIn", type: "address" }, { name: "tokenOut", type: "address" }, { name: "amountIn", type: "uint256" }, { name: "data", type: "bytes" }],                           outputs: [{ type: "uint256" }] },
  { name: "validate", type: "function", stateMutability: "pure",        inputs: [{ name: "tokenIn", type: "address" }, { name: "tokenOut", type: "address" }, { name: "amountIn", type: "uint256" }, { name: "data", type: "bytes" }],                           outputs: [{ name: "valid", type: "bool" }, { name: "reason", type: "string" }] },
  { name: "execute",  type: "function", stateMutability: "nonpayable",  inputs: [{ name: "tokenIn", type: "address" }, { name: "tokenOut", type: "address" }, { name: "amountIn", type: "uint256" }, { name: "minAmountOut", type: "uint256" }, { name: "data", type: "bytes" }], outputs: [{ type: "uint256" }] },
] as const;

// ─── Phase 3: MockSubAgentHub ─────────────────────────────────────────────────
export const SUB_AGENT_HUB_ABI = [
  { name: "orchestratorBudget", type: "function", stateMutability: "view",        inputs: [],                                                                                                                           outputs: [{ type: "uint256" }] },
  { name: "totalAllocated",     type: "function", stateMutability: "view",        inputs: [],                                                                                                                           outputs: [{ type: "uint256" }] },
  { name: "totalBorrowed",      type: "function", stateMutability: "view",        inputs: [],                                                                                                                           outputs: [{ type: "uint256" }] },
  { name: "totalRepaid",        type: "function", stateMutability: "view",        inputs: [],                                                                                                                           outputs: [{ type: "uint256" }] },
  { name: "agentCount",         type: "function", stateMutability: "view",        inputs: [],                                                                                                                           outputs: [{ type: "uint256" }] },
  { name: "totalProfit",        type: "function", stateMutability: "view",        inputs: [],                                                                                                                           outputs: [{ type: "uint256" }] },
  {
    name: "agents", type: "function", stateMutability: "view",
    inputs: [{ name: "agentId", type: "uint256" }],
    outputs: [{ name: "record", type: "tuple", components: [
      { name: "agentAddress", type: "address" },
      { name: "agentName",    type: "string" },
      { name: "budget",       type: "uint256" },
      { name: "borrowed",     type: "uint256" },
      { name: "totalRepaid",  type: "uint256" },
      { name: "loanCount",    type: "uint256" },
      { name: "active",       type: "bool" },
    ] }],
  },
  {
    name: "getAgent", type: "function", stateMutability: "view",
    inputs: [{ name: "agentId", type: "uint256" }],
    outputs: [{ name: "record", type: "tuple", components: [
      { name: "agentAddress", type: "address" },
      { name: "agentName",    type: "string" },
      { name: "budget",       type: "uint256" },
      { name: "borrowed",     type: "uint256" },
      { name: "totalRepaid",  type: "uint256" },
      { name: "loanCount",    type: "uint256" },
      { name: "active",       type: "bool" },
    ] }],
  },
  {
    name: "registerAgent", type: "function", stateMutability: "nonpayable",
    inputs: [
      { name: "agentId",      type: "uint256" },
      { name: "agentAddress", type: "address" },
      { name: "agentName",    type: "string" },
      { name: "budget",       type: "uint256" },
    ],
    outputs: [],
  },
  { name: "recordBorrow", type: "function", stateMutability: "nonpayable", inputs: [{ name: "agentId", type: "uint256" }, { name: "amount", type: "uint256" }], outputs: [] },
  { name: "recordRepay",  type: "function", stateMutability: "nonpayable", inputs: [{ name: "agentId", type: "uint256" }, { name: "amount", type: "uint256" }], outputs: [] },
  // Events
  { name: "AgentRegistered", type: "event", inputs: [{ name: "agentId", type: "uint256", indexed: true }, { name: "agent", type: "address", indexed: true }, { name: "name", type: "string", indexed: false }, { name: "budget", type: "uint256", indexed: false }] },
  { name: "BorrowRecorded",  type: "event", inputs: [{ name: "agentId", type: "uint256", indexed: true }, { name: "amount", type: "uint256", indexed: false }] },
  { name: "RepayRecorded",   type: "event", inputs: [{ name: "agentId", type: "uint256", indexed: true }, { name: "amount", type: "uint256", indexed: false }] },
] as const;

// ─── All custom errors (registry + kernel) included in REGISTRY_ABI so that
// simulateContract on trigger() can decode errors that bubble up from the kernel.
export const ALL_PROTOCOL_ERRORS = [
  // Registry
  { name: "EnvelopeNotFound",        type: "error", inputs: [] },
  { name: "EnvelopeNotActive",       type: "error", inputs: [] },
  { name: "ConditionsMismatch",      type: "error", inputs: [] },
  { name: "IntentMismatch",          type: "error", inputs: [] },
  { name: "ConditionNotMet",         type: "error", inputs: [] },
  { name: "OracleStale",             type: "error", inputs: [] },
  { name: "OracleInvalidAnswer",     type: "error", inputs: [] },
  { name: "KeeperRewardTooHigh",     type: "error", inputs: [] },
  { name: "NotIssuer",               type: "error", inputs: [] },
  { name: "EnvelopeAlreadyExists",   type: "error", inputs: [] },
  { name: "EnvelopeNotExpired",      type: "error", inputs: [] },
  { name: "RescueAmountZero",        type: "error", inputs: [] },
  // Kernel (bubble up through registry → kernel.executeIntent)
  { name: "IntentExpired",               type: "error", inputs: [] },
  { name: "CapabilityExpired",           type: "error", inputs: [] },
  { name: "InvalidCapabilitySig",        type: "error", inputs: [] },
  { name: "InvalidIntentSig",            type: "error", inputs: [] },
  { name: "SolverNotApproved",           type: "error", inputs: [] },
  { name: "CapabilityHashMismatch",      type: "error", inputs: [] },
  { name: "CommitmentMismatch",          type: "error", inputs: [] },
  { name: "OwnerMismatch",               type: "error", inputs: [] },
  { name: "NullifierSpent",              type: "error", inputs: [] },
  { name: "PositionEncumberedError",     type: "error", inputs: [] },
  { name: "AdapterNotRegistered",        type: "error", inputs: [] },
  { name: "WrongScope",                  type: "error", inputs: [] },
  { name: "CapabilityNonceRevoked",      type: "error", inputs: [] },
  { name: "DelegationDepthNotSupported", type: "error", inputs: [] },
  { name: "UnauthorizedSubmitter",       type: "error", inputs: [] },
  { name: "SolverFeeTooHigh",            type: "error", inputs: [] },
  { name: "InsufficientOutput",          type: "error", inputs: [] },
  { name: "PeriodLimitExceeded",         type: "error", inputs: [] },
  // Vault
  { name: "PositionNotFound",            type: "error", inputs: [] },
  { name: "PositionAlreadyExists",       type: "error", inputs: [] },
  { name: "PositionIsEncumbered",        type: "error", inputs: [] },
  { name: "NotPositionOwner",            type: "error", inputs: [] },
  { name: "AlreadyEncumbered",           type: "error", inputs: [] },
  { name: "TokenNotAllowlisted",         type: "error", inputs: [] },
  { name: "ZeroAmount",                  type: "error", inputs: [] },
  { name: "ZeroAddress",                 type: "error", inputs: [] },
] as const;

// ─── Phase 4: MockPriceOracle ─────────────────────────────────────────────────
export const MOCK_PRICE_ORACLE_ABI = [
  { name: "decimals",          type: "function", stateMutability: "pure",        inputs: [],                                    outputs: [{ type: "uint8" }] },
  { name: "price",             type: "function", stateMutability: "view",        inputs: [],                                    outputs: [{ type: "int256" }] },
  { name: "setPrice",          type: "function", stateMutability: "nonpayable",  inputs: [{ name: "_price", type: "int256" }],  outputs: [] },
  { name: "latestRoundData",   type: "function", stateMutability: "view",        inputs: [],                                    outputs: [{ name: "roundId", type: "uint80" }, { name: "answer", type: "int256" }, { name: "startedAt", type: "uint256" }, { name: "updatedAt", type: "uint256" }, { name: "answeredInRound", type: "uint80" }] },
  { name: "PriceSet", type: "event", inputs: [{ name: "newPrice", type: "int256", indexed: true }] },
] as const;

// ─── Phase 4: PriceSwapAdapter ────────────────────────────────────────────────
export const PRICE_SWAP_ADAPTER_ABI = [
  { name: "name",      type: "function", stateMutability: "pure", inputs: [], outputs: [{ type: "string" }] },
  { name: "quote",     type: "function", stateMutability: "view", inputs: [{ name: "tokenIn", type: "address" }, { name: "tokenOut", type: "address" }, { name: "amountIn", type: "uint256" }, { name: "data", type: "bytes" }], outputs: [{ type: "uint256" }] },
  { name: "validate",  type: "function", stateMutability: "view", inputs: [{ name: "tokenIn", type: "address" }, { name: "tokenOut", type: "address" }, { name: "amountIn", type: "uint256" }, { name: "data", type: "bytes" }], outputs: [{ name: "valid", type: "bool" }, { name: "reason", type: "string" }] },
  { name: "execute",   type: "function", stateMutability: "nonpayable", inputs: [{ name: "tokenIn", type: "address" }, { name: "tokenOut", type: "address" }, { name: "amountIn", type: "uint256" }, { name: "minAmountOut", type: "uint256" }, { name: "data", type: "bytes" }], outputs: [{ type: "uint256" }] },
] as const;

// ─── Phase 5: MockHealthOracle ────────────────────────────────────────────────
export const MOCK_HEALTH_ORACLE_ABI = [
  { name: "decimals",           type: "function", stateMutability: "pure",       inputs: [],                                          outputs: [{ type: "uint8" }] },
  { name: "healthFactor",       type: "function", stateMutability: "view",       inputs: [],                                          outputs: [{ type: "int256" }] },
  { name: "setHealthFactor",    type: "function", stateMutability: "nonpayable", inputs: [{ name: "_hf", type: "int256" }],            outputs: [] },
  { name: "latestRoundData",    type: "function", stateMutability: "view",       inputs: [],                                          outputs: [{ name: "roundId", type: "uint80" }, { name: "answer", type: "int256" }, { name: "startedAt", type: "uint256" }, { name: "updatedAt", type: "uint256" }, { name: "answeredInRound", type: "uint80" }] },
  { name: "HealthFactorSet", type: "event", inputs: [{ name: "newHealthFactor", type: "int256", indexed: true }] },
] as const;

// ─── Phase 5: MockAavePool ────────────────────────────────────────────────────
export const MOCK_AAVE_POOL_ABI = [
  { name: "openPosition",     type: "function", stateMutability: "nonpayable", inputs: [{ name: "user", type: "address" }, { name: "collateralUsdc", type: "uint256" }, { name: "debtUsdc", type: "uint256" }], outputs: [] },
  { name: "getDebt",          type: "function", stateMutability: "view",       inputs: [{ name: "user", type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "getPosition",      type: "function", stateMutability: "view",       inputs: [{ name: "user", type: "address" }], outputs: [{ name: "pos", type: "tuple", components: [{ name: "collateralUsdc", type: "uint256" }, { name: "debtUsdc", type: "uint256" }, { name: "active", type: "bool" }] }] },
  { name: "repayNoTransfer",  type: "function", stateMutability: "nonpayable", inputs: [{ name: "user", type: "address" }, { name: "amount", type: "uint256" }], outputs: [] },
  { name: "PositionOpened", type: "event", inputs: [{ name: "user", type: "address", indexed: true }, { name: "collateral", type: "uint256", indexed: false }, { name: "debt", type: "uint256", indexed: false }] },
  { name: "DebtRepaid",     type: "event", inputs: [{ name: "user", type: "address", indexed: true }, { name: "amount", type: "uint256", indexed: false }, { name: "remaining", type: "uint256", indexed: false }] },
] as const;

// ─── Phase 6: MockCreditGatedLender ──────────────────────────────────────────
export const MOCK_CREDIT_GATED_LENDER_ABI = [
  { name: "LIMIT_NEW",        type: "function", stateMutability: "pure",        inputs: [], outputs: [{ type: "uint256" }] },
  { name: "LIMIT_BRONZE",     type: "function", stateMutability: "pure",        inputs: [], outputs: [{ type: "uint256" }] },
  { name: "LIMIT_SILVER",     type: "function", stateMutability: "pure",        inputs: [], outputs: [{ type: "uint256" }] },
  { name: "LIMIT_GOLD",       type: "function", stateMutability: "pure",        inputs: [], outputs: [{ type: "uint256" }] },
  { name: "LIMIT_PLATINUM",   type: "function", stateMutability: "pure",        inputs: [], outputs: [{ type: "uint256" }] },
  { name: "getLimitForCap",   type: "function", stateMutability: "view",        inputs: [{ name: "capabilityHash", type: "bytes32" }], outputs: [{ name: "limit", type: "uint256" }, { name: "tier", type: "uint8" }] },
  { name: "outstandingDebt",  type: "function", stateMutability: "view",        inputs: [{ name: "capabilityHash", type: "bytes32" }], outputs: [{ type: "uint256" }] },
  { name: "borrow",           type: "function", stateMutability: "nonpayable",  inputs: [{ name: "capabilityHash", type: "bytes32" }, { name: "amount", type: "uint256" }], outputs: [] },
  { name: "repay",            type: "function", stateMutability: "nonpayable",  inputs: [{ name: "capabilityHash", type: "bytes32" }, { name: "amount", type: "uint256" }], outputs: [] },
  { name: "Borrowed", type: "event", inputs: [{ name: "capabilityHash", type: "bytes32", indexed: true }, { name: "amount", type: "uint256", indexed: false }, { name: "tier", type: "uint8", indexed: false }] },
  { name: "Repaid",   type: "event", inputs: [{ name: "capabilityHash", type: "bytes32", indexed: true }, { name: "amount", type: "uint256", indexed: false }] },
] as const;

// ─── Phase 7: MockConsensusHub ────────────────────────────────────────────────
export const MOCK_CONSENSUS_HUB_ABI = [
  { name: "proposalCount",   type: "function", stateMutability: "view",       inputs: [], outputs: [{ type: "uint256" }] },
  { name: "propose",         type: "function", stateMutability: "nonpayable", inputs: [{ name: "intentHash", type: "bytes32" }, { name: "requiredApprovals", type: "uint8" }, { name: "approvedSigners", type: "address[]" }], outputs: [{ name: "proposalId", type: "bytes32" }] },
  { name: "approve",         type: "function", stateMutability: "nonpayable", inputs: [{ name: "proposalId", type: "bytes32" }], outputs: [] },
  { name: "markExecuted",    type: "function", stateMutability: "nonpayable", inputs: [{ name: "proposalId", type: "bytes32" }], outputs: [] },
  { name: "isExecutable",    type: "function", stateMutability: "view",       inputs: [{ name: "proposalId", type: "bytes32" }], outputs: [{ type: "bool" }] },
  { name: "getApprovalCount",type: "function", stateMutability: "view",       inputs: [{ name: "proposalId", type: "bytes32" }], outputs: [{ type: "uint8" }] },
  { name: "getSignerSet",    type: "function", stateMutability: "view",       inputs: [{ name: "proposalId", type: "bytes32" }], outputs: [{ type: "address[]" }] },
  { name: "signerHasApproved",type:"function", stateMutability: "view",       inputs: [{ name: "proposalId", type: "bytes32" }, { name: "signer", type: "address" }], outputs: [{ type: "bool" }] },
  {
    name: "proposals", type: "function", stateMutability: "view",
    inputs: [{ name: "proposalId", type: "bytes32" }],
    outputs: [{ name: "p", type: "tuple", components: [
      { name: "intentHash",        type: "bytes32" },
      { name: "requiredApprovals", type: "uint8" },
      { name: "approvalCount",     type: "uint8" },
      { name: "executed",          type: "bool" },
      { name: "active",            type: "bool" },
    ]}],
  },
  { name: "Proposed",  type: "event", inputs: [{ name: "proposalId", type: "bytes32", indexed: true }, { name: "intentHash", type: "bytes32", indexed: true }, { name: "required", type: "uint8", indexed: false }, { name: "signers", type: "address[]", indexed: false }] },
  { name: "Approved",  type: "event", inputs: [{ name: "proposalId", type: "bytes32", indexed: true }, { name: "signer", type: "address", indexed: true }, { name: "count", type: "uint8", indexed: false }, { name: "required", type: "uint8", indexed: false }] },
  { name: "Executed",  type: "event", inputs: [{ name: "proposalId", type: "bytes32", indexed: true }] },
] as const;

// ─── Kernel (direct executeIntent + revokeNonce for Publish-Key demo) ──────────
export const KERNEL_DIRECT_ABI = [
  {
    name: "executeIntent", type: "function", stateMutability: "nonpayable",
    inputs: [
      { name: "position",   type: "tuple",  components: [{ name: "owner", type: "address" }, { name: "asset", type: "address" }, { name: "amount", type: "uint256" }, { name: "salt", type: "bytes32" }] },
      { name: "capability", type: "tuple",  components: [{ name: "issuer", type: "address" }, { name: "grantee", type: "address" }, { name: "scope", type: "bytes32" }, { name: "expiry", type: "uint256" }, { name: "nonce", type: "bytes32" }, { name: "constraints", type: "tuple", components: [{ name: "maxSpendPerPeriod", type: "uint256" }, { name: "periodDuration", type: "uint256" }, { name: "minReturnBps", type: "uint256" }, { name: "allowedAdapters", type: "address[]" }, { name: "allowedTokensIn", type: "address[]" }, { name: "allowedTokensOut", type: "address[]" }] }, { name: "parentCapabilityHash", type: "bytes32" }, { name: "delegationDepth", type: "uint8" }] },
      { name: "intent",     type: "tuple",  components: [{ name: "positionCommitment", type: "bytes32" }, { name: "capabilityHash", type: "bytes32" }, { name: "adapter", type: "address" }, { name: "adapterData", type: "bytes" }, { name: "minReturn", type: "uint256" }, { name: "deadline", type: "uint256" }, { name: "nonce", type: "bytes32" }, { name: "outputToken", type: "address" }, { name: "returnTo", type: "address" }, { name: "submitter", type: "address" }, { name: "solverFeeBps", type: "uint16" }] },
      { name: "capSig",     type: "bytes" },
      { name: "intentSig",  type: "bytes" },
    ],
    outputs: [],
  },
  { name: "revokeCapabilityNonce", type: "function", stateMutability: "nonpayable", inputs: [{ name: "nonce", type: "bytes32" }], outputs: [] },
  // Errors for simulateContract
  { name: "PeriodLimitExceeded",         type: "error", inputs: [] },
  { name: "CapabilityNonceRevoked",      type: "error", inputs: [] },
  { name: "CapabilityExpired",           type: "error", inputs: [] },
  { name: "InvalidCapabilitySig",        type: "error", inputs: [] },
  { name: "InvalidIntentSig",            type: "error", inputs: [] },
  { name: "SolverNotApproved",           type: "error", inputs: [] },
  { name: "CommitmentMismatch",          type: "error", inputs: [] },
  { name: "OwnerMismatch",               type: "error", inputs: [] },
  { name: "NullifierSpent",              type: "error", inputs: [] },
  { name: "PositionEncumberedError",     type: "error", inputs: [] },
  { name: "AdapterNotRegistered",        type: "error", inputs: [] },
  { name: "WrongScope",                  type: "error", inputs: [] },
  { name: "DelegationDepthNotSupported", type: "error", inputs: [] },
  { name: "UnauthorizedSubmitter",       type: "error", inputs: [] },
  { name: "SolverFeeTooHigh",            type: "error", inputs: [] },
  { name: "InsufficientOutput",          type: "error", inputs: [] },
  { name: "AdapterValidationFailed",     type: "error", inputs: [{ name: "reason", type: "string" }] },
  // IntentExecuted event
  { name: "IntentExecuted", type: "event", inputs: [
    { name: "nullifier",         type: "bytes32",  indexed: true },
    { name: "positionIn",        type: "bytes32",  indexed: false },
    { name: "positionOut",       type: "bytes32",  indexed: false },
    { name: "adapter",           type: "address",  indexed: true },
    { name: "amountIn",          type: "uint256",  indexed: false },
    { name: "amountOut",         type: "uint256",  indexed: false },
    { name: "receiptHash",       type: "bytes32",  indexed: false },
  ]},
  { name: "IntentRejected", type: "event", inputs: [
    { name: "capabilityHash",    type: "bytes32", indexed: true },
    { name: "grantee",           type: "address", indexed: true },
    { name: "reason",            type: "bytes32", indexed: false },
    { name: "spentSoFar",        type: "uint256", indexed: false },
    { name: "limit",             type: "uint256", indexed: false },
  ]},
] as const;

// ── MockCapitalPool (Capital Provider / Lend tab) ─────────────────────────────
export const MOCK_CAPITAL_POOL_ABI = [
  { name: "provideCapital",      type: "function", stateMutability: "nonpayable", inputs: [{ name: "amount", type: "uint256" }], outputs: [] },
  { name: "withdrawCapital",     type: "function", stateMutability: "nonpayable", inputs: [{ name: "amount", type: "uint256" }], outputs: [] },
  { name: "assignTier",          type: "function", stateMutability: "nonpayable", inputs: [{ name: "botId", type: "uint256" }, { name: "tier", type: "uint16" }], outputs: [] },
  { name: "borrow",              type: "function", stateMutability: "nonpayable", inputs: [{ name: "botId", type: "uint256" }, { name: "amount", type: "uint256" }], outputs: [] },
  { name: "repay",               type: "function", stateMutability: "nonpayable", inputs: [{ name: "botId", type: "uint256" }, { name: "principal", type: "uint256" }, { name: "interest", type: "uint256" }], outputs: [] },
  { name: "claimYield",          type: "function", stateMutability: "nonpayable", inputs: [], outputs: [] },
  { name: "pauseBorrowing",      type: "function", stateMutability: "nonpayable", inputs: [], outputs: [] },
  { name: "resumeBorrowing",     type: "function", stateMutability: "nonpayable", inputs: [], outputs: [] },
  { name: "setTierLimit",        type: "function", stateMutability: "nonpayable", inputs: [{ name: "tier", type: "uint16" }, { name: "limit", type: "uint256" }], outputs: [] },
  { name: "setUtilizationGuard", type: "function", stateMutability: "nonpayable", inputs: [{ name: "bps", type: "uint256" }], outputs: [] },
  { name: "getDebt",             type: "function", stateMutability: "view",       inputs: [{ name: "botId", type: "uint256" }], outputs: [{ type: "uint256" }] },
  { name: "getUtilizationBps",   type: "function", stateMutability: "view",       inputs: [], outputs: [{ type: "uint256" }] },
  { name: "pendingYield",        type: "function", stateMutability: "view",       inputs: [{ name: "lender", type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "getLenderStats",      type: "function", stateMutability: "view",
    inputs: [{ name: "lender", type: "address" }],
    outputs: [
      { name: "capital",       type: "uint256" },
      { name: "yieldPending",  type: "uint256" },
      { name: "yieldClaimed",  type: "uint256" },
      { name: "utilizationBps",type: "uint256" },
    ],
  },
  { name: "getPoolStats",        type: "function", stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "poolTotalCapital",     type: "uint256" },
      { name: "poolTotalBorrowed",    type: "uint256" },
      { name: "poolAvailable",        type: "uint256" },
      { name: "poolUtilizationBps",   type: "uint256" },
      { name: "poolTotalYieldEarned", type: "uint256" },
      { name: "poolBorrowingPaused",  type: "bool" },
    ],
  },
  { name: "totalCapital",        type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "totalBorrowed",       type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "borrowingPaused",     type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
  { name: "tierLimit",           type: "function", stateMutability: "view", inputs: [{ name: "tier", type: "uint16" }], outputs: [{ type: "uint256" }] },
  { name: "lenderCapital",       type: "function", stateMutability: "view", inputs: [{ name: "lender", type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "botTier",             type: "function", stateMutability: "view", inputs: [{ name: "botId", type: "uint256" }], outputs: [{ type: "uint16" }] },
  { name: "CapitalProvided",     type: "event", inputs: [{ name: "lender", type: "address", indexed: true }, { name: "amount", type: "uint256", indexed: false }, { name: "newTotal", type: "uint256", indexed: false }] },
  { name: "Borrowed",            type: "event", inputs: [{ name: "botId", type: "uint256", indexed: true }, { name: "borrower", type: "address", indexed: true }, { name: "amount", type: "uint256", indexed: false }] },
  { name: "Repaid",              type: "event", inputs: [{ name: "botId", type: "uint256", indexed: true }, { name: "repayer", type: "address", indexed: true }, { name: "principal", type: "uint256", indexed: false }, { name: "interest", type: "uint256", indexed: false }] },
  { name: "BorrowingPaused",     type: "event", inputs: [{ name: "by", type: "address", indexed: true }, { name: "utilization", type: "uint256", indexed: false }] },
  { name: "BorrowingResumed",    type: "event", inputs: [{ name: "by", type: "address", indexed: true }] },
  { name: "YieldClaimed",        type: "event", inputs: [{ name: "lender", type: "address", indexed: true }, { name: "amount", type: "uint256", indexed: false }] },
] as const;

// ── PoolPauseAdapter ──────────────────────────────────────────────────────────
export const POOL_PAUSE_ADAPTER_ABI = [
  { name: "name",     type: "function", stateMutability: "pure",        inputs: [], outputs: [{ type: "string" }] },
  { name: "target",   type: "function", stateMutability: "pure",        inputs: [], outputs: [{ type: "address" }] },
  { name: "quote",    type: "function", stateMutability: "pure",        inputs: [{ name: "", type: "address" }, { name: "", type: "address" }, { name: "amountIn", type: "uint256" }, { name: "", type: "bytes" }], outputs: [{ type: "uint256" }] },
  { name: "validate", type: "function", stateMutability: "pure",        inputs: [{ name: "tokenIn", type: "address" }, { name: "tokenOut", type: "address" }, { name: "amountIn", type: "uint256" }, { name: "data", type: "bytes" }], outputs: [{ name: "valid", type: "bool" }, { name: "reason", type: "string" }] },
  { name: "execute",  type: "function", stateMutability: "nonpayable",  inputs: [{ name: "tokenIn", type: "address" }, { name: "", type: "address" }, { name: "amountIn", type: "uint256" }, { name: "minAmountOut", type: "uint256" }, { name: "data", type: "bytes" }], outputs: [{ name: "amountOut", type: "uint256" }] },
] as const;

// ── MockReverseSwapAdapter ────────────────────────────────────────────────────
export const MOCK_REVERSE_SWAP_ADAPTER_ABI = [
  { name: "quote",    type: "function", stateMutability: "view",       inputs: [{ name: "", type: "address" }, { name: "", type: "address" }, { name: "amountIn", type: "uint256" }, { name: "", type: "bytes" }], outputs: [{ type: "uint256" }] },
  { name: "validate", type: "function", stateMutability: "view",       inputs: [{ name: "tokenIn", type: "address" }, { name: "tokenOut", type: "address" }, { name: "amountIn", type: "uint256" }, { name: "", type: "bytes" }], outputs: [{ name: "valid", type: "bool" }, { name: "reason", type: "string" }] },
  { name: "execute",  type: "function", stateMutability: "nonpayable", inputs: [{ name: "tokenIn", type: "address" }, { name: "", type: "address" }, { name: "amountIn", type: "uint256" }, { name: "minAmountOut", type: "uint256" }, { name: "", type: "bytes" }], outputs: [{ name: "amountOut", type: "uint256" }] },
] as const;
