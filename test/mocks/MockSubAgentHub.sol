// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockSubAgentHub
/// @notice Application-layer orchestrator that tracks budget allocations and repayment
///         histories across a fleet of sub-agents.
///
/// Context:
///   In Phase 1, CapabilityKernel enforces delegationDepth == 0 (no on-chain delegation chains).
///   This hub provides the application-layer enforcement that mirrors what Phase 2+ on-chain
///   delegation (parentCapabilityHash + delegationDepth > 0) will enforce natively.
///
///   Orchestrator sets a total USDC budget. Each sub-agent is allocated a slice of that budget.
///   Sub-agents borrow from Clawloan independently under their slice. The hub enforces that no
///   sub-agent exceeds its allocation, and surfaces total orchestrator-level P&L.
///
/// Usage in the demo:
///   1. Deploy hub with orchestratorBudget = 3000e6 (3000 USDC).
///   2. registerAgent(1, addrA, "Sub-agent Alpha", 1500e6)
///   3. registerAgent(2, addrB, "Sub-agent Beta",  1500e6)
///   4. Before each borrow: call recordBorrow(agentId, amount) — reverts if over budget.
///   5. After each repay:   call recordRepay(agentId, amount).
contract MockSubAgentHub {

    // ─────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────

    struct AgentRecord {
        address agentAddress;
        string  agentName;
        uint256 budget;        // max USDC this sub-agent may borrow from orchestrator's allocation
        uint256 borrowed;      // currently outstanding borrowed amount
        uint256 totalRepaid;   // cumulative repaid amount (credit history)
        uint256 loanCount;     // number of completed repayment cycles
        bool    active;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    mapping(uint256 => AgentRecord) public agents;

    uint256 public agentCount;
    uint256 public orchestratorBudget;  // total USDC the orchestrator controls
    uint256 public totalAllocated;      // sum of all sub-agent budgets
    uint256 public totalBorrowed;       // sum of outstanding borrows across all sub-agents
    uint256 public totalRepaid;         // cumulative repaid across all sub-agents

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event AgentRegistered(uint256 indexed agentId, address indexed agent, string name, uint256 budget);
    event BorrowRecorded(uint256 indexed agentId, uint256 amount);
    event RepayRecorded(uint256 indexed agentId, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(uint256 _orchestratorBudget) {
        orchestratorBudget = _orchestratorBudget;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────

    function registerAgent(
        uint256 agentId,
        address agentAddress,
        string calldata agentName,
        uint256 budget
    ) external {
        require(!agents[agentId].active, "MockSubAgentHub: agent already registered");
        require(totalAllocated + budget <= orchestratorBudget, "MockSubAgentHub: exceeds orchestrator budget");

        agents[agentId] = AgentRecord({
            agentAddress: agentAddress,
            agentName:    agentName,
            budget:       budget,
            borrowed:     0,
            totalRepaid:  0,
            loanCount:    0,
            active:       true
        });
        totalAllocated += budget;
        agentCount++;

        emit AgentRegistered(agentId, agentAddress, agentName, budget);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Tracking
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Record a sub-agent borrow. Reverts if the agent's slice budget is exceeded.
    function recordBorrow(uint256 agentId, uint256 amount) external {
        AgentRecord storage agent = agents[agentId];
        require(agent.active, "MockSubAgentHub: agent not registered");
        require(
            agent.borrowed + amount <= agent.budget,
            "MockSubAgentHub: sub-agent budget exceeded"
        );

        agent.borrowed  += amount;
        totalBorrowed   += amount;

        emit BorrowRecorded(agentId, amount);
    }

    /// @notice Record a sub-agent repayment. Decrements outstanding borrow.
    function recordRepay(uint256 agentId, uint256 amount) external {
        AgentRecord storage agent = agents[agentId];
        require(agent.active, "MockSubAgentHub: agent not registered");

        agent.totalRepaid += amount;
        agent.loanCount   += 1;
        agent.borrowed     = agent.borrowed >= amount ? agent.borrowed - amount : 0;
        totalRepaid       += amount;

        emit RepayRecorded(agentId, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View
    // ─────────────────────────────────────────────────────────────────────────

    function getAgent(uint256 agentId) external view returns (AgentRecord memory) {
        return agents[agentId];
    }

    /// @notice Total profit across all sub-agents (totalRepaid - totalBorrowed, floored at 0).
    function totalProfit() external view returns (uint256) {
        return totalRepaid > totalBorrowed ? totalRepaid - totalBorrowed : 0;
    }
}
