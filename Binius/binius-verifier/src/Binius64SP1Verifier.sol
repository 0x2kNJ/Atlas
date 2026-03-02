// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

/// @title Binius64SP1Verifier
/// @notice Production-viable on-chain verifier for Binius64 proofs using SP1 zkVM wrapping.
///
/// ============================================================================
/// ARCHITECTURE: zkVM Wrapping
/// ============================================================================
///
///  The problem: verifying Binius64 natively on EVM costs ~71M gas (after Tier 1+2
///  optimizations) due to the lack of a CLMUL opcode. This is feasible on Arbitrum
///  but not on L1 or most L2s.
///
///  The solution: prove the verification off-chain, verify the proof on-chain.
///
///  Off-chain (Rust, ~10-30s proving time):
///    1. Generate a Binius64 SNARK proof π_binius for your circuit
///    2. Run the Binius64 verifier inside an SP1 zkVM guest program
///    3. SP1 produces a STARK proof π_sp1 that "the verifier accepted π_binius"
///    4. Compress π_sp1 into a Groth16 proof π_groth16 (~1-2s with SP1's compressor)
///
///  On-chain (this contract, ~220-280K gas):
///    1. Receive π_groth16 + public inputs (96 bytes)
///    2. Call SP1VerifierGateway.verifyProof(VKEY, publicValues, proofBytes)
///    3. Accept/reject the Binius64 claim
///    4. Optionally: gate on registered circuit IDs (CircuitRegistry feature)
///
///  Net result: L1-feasible Binius64 verification at Groth16 cost (~280K gas),
///  with the same security as native verification (SP1 is audited, open source).
///
/// ============================================================================
/// SECURITY MODEL
/// ============================================================================
///
///  circuit_id is computed inside the SP1 zkVM guest as keccak256(cs_bytes).
///  This means the SP1 proof cryptographically binds the circuit_id to the exact
///  ConstraintSystem that was verified — a prover cannot forge it.
///
///  CircuitRegistry (optional): owner can register which circuit IDs are accepted.
///  This prevents a valid proof for an unintended circuit from being accepted.
///  For permissionless use: call setCircuitRegistryEnabled(false) or omit registration.
///
/// ============================================================================
/// GAS COMPARISON
/// ============================================================================
///
///  | Approach                  | Gas (L1)  | Proving time | Status       |
///  |---------------------------|-----------|--------------|--------------|
///  | Native (this repo, opt.)  | ~71M      | none (L2 only)| feasible L2 |
///  | SP1 Groth16 wrapping      | ~280K     | 10-30s       | ✓ Live today |
///  | Risc0 Groth16 wrapping    | ~220K     | 10-30s       | ✓ Live today |
///  | CLMUL EIP (eventual)      | ~500K     | none         | 2-4 years   |
///
/// ============================================================================
/// SP1 INTEGRATION
/// ============================================================================
///
///  SP1 GitHub:  https://github.com/succinctlabs/sp1
///  SP1 Contracts: https://github.com/succinctlabs/sp1-contracts
///  SP1 Verifier Gateway (mainnet/Arbitrum/Base): 0x397A5f7f3dBd538f23DE225B51f532c34448dA9B
///  SP1 Verifier Gateway (Sepolia): 0x3B6041173B80E77f038f3F2C0f9744f04837185e
///
///  The SP1VerifierGateway routes to the correct verifier version based on the
///  vkey hash embedded in the proof. This means you don't need to redeploy this
///  contract when SP1 releases a new version — only the guest program changes.
///
/// ============================================================================
/// CURRENT VKEY (recompute after any guest program change)
/// ============================================================================
///
///  BINIUS64_VKEY = 0x00c8508697673f052b007f80dadec4ea96d520efc69aaf7ab7d322e0eb60d868
///  Computed with: cd sp1-guest && cargo run --bin prove -- vkey
///  Guest version: binius64-sp1-program v0.1.0 (security-fix: circuit_id in-guest)

/// @dev Minimal SP1 verifier interface (matches ISP1Verifier in sp1-contracts)
interface ISP1Verifier {
    function verifyProof(
        bytes32 programVKey,
        bytes calldata publicValues,
        bytes calldata proofBytes
    ) external;
}

contract Binius64SP1Verifier {
    // -----------------------------------------------------------------------
    //  Immutable configuration
    // -----------------------------------------------------------------------

    /// @notice SP1VerifierGateway address.
    ///         Mainnet/Arbitrum/Base: 0x397A5f7f3dBd538f23DE225B51f532c34448dA9B
    ///         Sepolia:               0x3B6041173B80E77f038f3F2C0f9744f04837185e
    ISP1Verifier public immutable SP1_VERIFIER;

    /// @notice The SP1 program verification key for the Binius64 guest program.
    ///         This is the hash of the compiled SP1 ELF binary. Fixed for a given
    ///         guest program version; update when the guest changes.
    ///         Current value: 0x00c8508697673f052b007f80dadec4ea96d520efc69aaf7ab7d322e0eb60d868
    bytes32 public immutable BINIUS64_VKEY;

    // -----------------------------------------------------------------------
    //  Circuit registry (optional security feature)
    // -----------------------------------------------------------------------

    address public owner;

    /// @notice When true, only registered circuit IDs are accepted.
    ///         Set to false for permissionless operation (any valid Binius64 proof
    ///         with any circuit is accepted, as long as the SP1 proof is valid).
    bool public circuitRegistryEnabled;

    /// @notice Registered circuit IDs. circuitId = keccak256(ConstraintSystem bytes).
    ///         Computed deterministically by the guest program — not supplied by prover.
    mapping(bytes32 => bool) public registeredCircuits;

    // -----------------------------------------------------------------------
    //  Public input structure (3 × 32 bytes = 96 bytes on-chain)
    // -----------------------------------------------------------------------

    /// @notice Public inputs committed to by the Binius64 SP1 guest.
    ///         ABI-encoded as (bytes32, bytes32, bytes32) — no dynamic types.
    struct PublicInputs {
        /// keccak256(serialized ConstraintSystem bytes) — computed in-guest.
        /// Cryptographically binds the SP1 proof to a specific circuit.
        bytes32 circuitId;
        /// keccak256(LE-encoded public witness words) — commitment to the public inputs.
        bytes32 publicInputsHash;
        /// keccak256(raw binius64 proof bytes).
        bytes32 proofHash;
    }

    // -----------------------------------------------------------------------
    //  Events
    // -----------------------------------------------------------------------

    event ProofVerified(
        bytes32 indexed circuitId,
        bytes32 indexed publicInputHash,
        address indexed submitter
    );

    event CircuitRegistered(bytes32 indexed circuitId);
    event CircuitDeregistered(bytes32 indexed circuitId);
    event CircuitRegistryToggled(bool enabled);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // -----------------------------------------------------------------------
    //  Errors
    // -----------------------------------------------------------------------

    error CircuitNotRegistered(bytes32 circuitId);
    error Unauthorized();
    error ZeroSP1VerifierAddress();
    error ZeroBinius64VKey();

    // -----------------------------------------------------------------------
    //  Constructor
    // -----------------------------------------------------------------------

    constructor(address sp1Verifier, bytes32 binius64VKey) {
        // Validate that neither critical immutable is the zero value.
        // A zero sp1Verifier would silently accept all proofs (external call
        // to address(0) succeeds and returns empty bytes, bypassing verification).
        // A zero vkey would allow any SP1 program to satisfy the check.
        if (sp1Verifier == address(0)) revert ZeroSP1VerifierAddress();
        if (binius64VKey == bytes32(0)) revert ZeroBinius64VKey();

        SP1_VERIFIER = ISP1Verifier(sp1Verifier);
        BINIUS64_VKEY = binius64VKey;
        owner = msg.sender;
        // Circuit registry is disabled by default — permissionless operation.
        // Enable and register circuits to restrict which proofs are accepted.
        circuitRegistryEnabled = false;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    // -----------------------------------------------------------------------
    //  Admin: circuit registry
    // -----------------------------------------------------------------------

    /// @notice Register a circuit ID so it can be used in verify().
    ///         circuitId = keccak256(ConstraintSystem bytes), computed by:
    ///         `cargo run --bin prove -- info --cs circuit.cs ...`
    function registerCircuit(bytes32 circuitId) external onlyOwner {
        registeredCircuits[circuitId] = true;
        emit CircuitRegistered(circuitId);
    }

    /// @notice Remove a circuit from the registry (e.g. if it is deprecated).
    function deregisterCircuit(bytes32 circuitId) external onlyOwner {
        registeredCircuits[circuitId] = false;
        emit CircuitDeregistered(circuitId);
    }

    /// @notice Enable or disable the circuit registry check.
    ///         When disabled, any valid SP1-wrapped Binius64 proof is accepted.
    function setCircuitRegistryEnabled(bool enabled) external onlyOwner {
        circuitRegistryEnabled = enabled;
        emit CircuitRegistryToggled(enabled);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // -----------------------------------------------------------------------
    //  Verification — single proof
    // -----------------------------------------------------------------------

    /// @notice Verify a Binius64 proof wrapped in an SP1 Groth16 proof.
    ///
    /// @param publicValues  abi.encode(circuitId, publicInputsHash, proofHash) — 96 bytes.
    ///                      Produced by `cargo run --bin prove -- prove`.
    /// @param sp1Proof      SP1 Groth16 proof bytes (~256 bytes).
    ///
    /// Reverts if SP1 verification fails, or if circuit registry is enabled and
    /// the circuit is not registered. Gas: ~220-280K (one BN254 pairing).
    function verify(bytes calldata publicValues, bytes calldata sp1Proof) external {
        SP1_VERIFIER.verifyProof(BINIUS64_VKEY, publicValues, sp1Proof);

        (bytes32 circuitId, bytes32 publicInputsHash,) =
            abi.decode(publicValues, (bytes32, bytes32, bytes32));

        if (circuitRegistryEnabled && !registeredCircuits[circuitId]) {
            revert CircuitNotRegistered(circuitId);
        }

        emit ProofVerified(circuitId, publicInputsHash, msg.sender);
    }

    /// @notice Stateless verification — no event, no registry check.
    ///         Use with eth_call for off-chain pre-verification before submitting.
    function verifyView(bytes calldata publicValues, bytes calldata sp1Proof) external {
        SP1_VERIFIER.verifyProof(BINIUS64_VKEY, publicValues, sp1Proof);
    }

    // -----------------------------------------------------------------------
    //  Verification — batch (multiple proofs in one tx, shared base tx cost)
    // -----------------------------------------------------------------------

    /// @notice Verify multiple Binius64 proofs in a single transaction.
    ///         Each proof is verified independently. Gas: ~220-280K per proof
    ///         plus one base tx cost (~21K) shared across all proofs.
    ///         Useful for keepers submitting multiple envelope enforcements.
    function batchVerify(
        bytes[] calldata publicValuesArr,
        bytes[] calldata sp1ProofsArr
    ) external {
        require(publicValuesArr.length == sp1ProofsArr.length, "length mismatch");
        for (uint256 i; i < publicValuesArr.length; ++i) {
            SP1_VERIFIER.verifyProof(BINIUS64_VKEY, publicValuesArr[i], sp1ProofsArr[i]);

            (bytes32 circuitId, bytes32 publicInputsHash,) =
                abi.decode(publicValuesArr[i], (bytes32, bytes32, bytes32));

            if (circuitRegistryEnabled && !registeredCircuits[circuitId]) {
                revert CircuitNotRegistered(circuitId);
            }

            emit ProofVerified(circuitId, publicInputsHash, msg.sender);
        }
    }

    // -----------------------------------------------------------------------
    //  Verification + atomic protocol call (envelope integration pattern)
    // -----------------------------------------------------------------------

    /// @notice Verify a Binius64 proof then atomically call a target contract.
    ///         Enables the "prove-and-enforce" pattern for the envelope protocol:
    ///
    ///         1. Prover generates binius64 proof that collateral condition is met
    ///         2. Calls verifyAndCall(publicValues, sp1Proof, envelopeRegistry, enforceCalldata)
    ///         3. If proof is valid, EnvelopeRegistry.enforce() is called atomically
    ///         4. No re-entrancy risk: target.call happens after SP1 verification
    ///
    /// @param publicValues  SP1 public values (96 bytes)
    /// @param sp1Proof      SP1 Groth16 proof bytes
    /// @param target        Contract to call after successful verification
    /// @param callData      Calldata to send to target (e.g. enforce(eid, oracleData))
    /// @return result       Return data from the target call
    function verifyAndCall(
        bytes calldata publicValues,
        bytes calldata sp1Proof,
        address target,
        bytes calldata callData
    ) external returns (bytes memory result) {
        SP1_VERIFIER.verifyProof(BINIUS64_VKEY, publicValues, sp1Proof);

        (bytes32 circuitId, bytes32 publicInputsHash,) =
            abi.decode(publicValues, (bytes32, bytes32, bytes32));

        if (circuitRegistryEnabled && !registeredCircuits[circuitId]) {
            revert CircuitNotRegistered(circuitId);
        }

        emit ProofVerified(circuitId, publicInputsHash, msg.sender);

        bool success;
        (success, result) = target.call(callData);
        require(success, "target call failed");
    }
}
