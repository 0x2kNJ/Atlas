// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ICreditVerifier {
    function getCreditTier(bytes32 capabilityHash) external view returns (uint8);
}

/// @title MockCreditGatedLender
/// @notice A competing lending protocol that grants higher unsecured loan limits
///         to agents with verified Atlas credit histories.
///
/// Context:
///   The ZK Credit Passport demo shows that an agent's compliance history —
///   proven via Atlas ZK receipts — is a portable trust credential. Any protocol
///   can query CreditVerifier.getCreditTier(capHash) to determine the agent's tier
///   and offer correspondingly higher limits.
///
///   This demonstrates:
///     - Cross-protocol portability of Atlas credit proofs.
///     - The "agent credit score that preserves privacy" primitive from STRATEGY.md.
///     - Network effects: as more protocols check Atlas tiers, agents are incentivized
///       to build on-chain credit history through Atlas.
///
/// Loan limits by tier (USDC, 6-decimal):
///   0 (NEW):       $100   USDC
///   1 (BRONZE):    $500   USDC
///   2 (SILVER):    $2,000 USDC
///   3 (GOLD):      $5,000 USDC
///   4 (PLATINUM):  $10,000 USDC
///
/// Outstanding debt is tracked per capability hash. An agent must repay before
/// borrowing again at the same tier.
contract MockCreditGatedLender {

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant LIMIT_NEW       = 100e6;
    uint256 public constant LIMIT_BRONZE    = 500e6;
    uint256 public constant LIMIT_SILVER    = 2_000e6;
    uint256 public constant LIMIT_GOLD      = 5_000e6;
    uint256 public constant LIMIT_PLATINUM  = 10_000e6;

    // ─── State ────────────────────────────────────────────────────────────────
    ICreditVerifier public immutable creditVerifier;
    IERC20          public immutable usdc;

    mapping(bytes32 => uint256) public outstandingDebt;  // capabilityHash → debt

    // ─── Events ───────────────────────────────────────────────────────────────
    event Borrowed(bytes32 indexed capabilityHash, uint256 amount, uint8 tier);
    event Repaid(bytes32 indexed capabilityHash, uint256 amount);

    constructor(address _creditVerifier, address _usdc) {
        creditVerifier = ICreditVerifier(_creditVerifier);
        usdc           = IERC20(_usdc);
    }

    // ─── View ─────────────────────────────────────────────────────────────────

    /// @notice Returns the current loan limit for a given capability hash (based on its tier).
    function getLimitForCap(bytes32 capabilityHash) public view returns (uint256 limit, uint8 tier) {
        tier = creditVerifier.getCreditTier(capabilityHash);
        if      (tier == 0) limit = LIMIT_NEW;
        else if (tier == 1) limit = LIMIT_BRONZE;
        else if (tier == 2) limit = LIMIT_SILVER;
        else if (tier == 3) limit = LIMIT_GOLD;
        else                limit = LIMIT_PLATINUM;
    }

    // ─── Actions ──────────────────────────────────────────────────────────────

    /// @notice Borrow USDC against the agent's Atlas credit tier.
    ///         Reverts if the requested amount exceeds the tier limit or if there
    ///         is already outstanding debt for this capability.
    function borrow(bytes32 capabilityHash, uint256 amount) external {
        require(outstandingDebt[capabilityHash] == 0, "MockCreditGatedLender: outstanding debt exists");

        (uint256 limit, uint8 tier) = getLimitForCap(capabilityHash);
        require(amount <= limit, "MockCreditGatedLender: amount exceeds tier limit");
        require(usdc.balanceOf(address(this)) >= amount, "MockCreditGatedLender: insufficient reserves");

        outstandingDebt[capabilityHash] = amount;
        usdc.transfer(msg.sender, amount);

        emit Borrowed(capabilityHash, amount, tier);
    }

    /// @notice Repay outstanding debt. Must approve this contract first.
    function repay(bytes32 capabilityHash, uint256 amount) external {
        require(outstandingDebt[capabilityHash] >= amount, "MockCreditGatedLender: repay exceeds debt");
        usdc.transferFrom(msg.sender, address(this), amount);
        outstandingDebt[capabilityHash] -= amount;
        emit Repaid(capabilityHash, amount);
    }
}
