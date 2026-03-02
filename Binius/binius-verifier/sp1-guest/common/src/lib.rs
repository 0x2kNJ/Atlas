/// Shared types for the Binius64 SP1 guest/host pipeline.
///
/// Data flow:
///   GuestInputs (private, stdin) → [SP1 zkVM: binius-verifier] → PublicInputs (public, stdout)
///   on-chain: Binius64SP1Verifier.sol decodes PublicInputs from SP1's publicValues bytes

use alloy_primitives::B256;
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
//  Public outputs  (committed to SP1 stdout → become publicValues on-chain)
// ---------------------------------------------------------------------------

/// Three bytes32 fields — no dynamic types, so abi.decode is trivially safe.
///
/// Matching Solidity:
///   (bytes32 circuitId, bytes32 publicInputsHash, bytes32 proofHash)
///     = abi.decode(publicValues, (bytes32, bytes32, bytes32))
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PublicInputs {
    /// keccak256 of the serialized ConstraintSystem bytes.
    /// Ties the SP1 proof to a specific circuit — if someone swaps the circuit,
    /// this hash changes and the on-chain verifier rejects it.
    pub circuit_id: B256,

    /// keccak256(little-endian u64 words of the public witness).
    /// Fixed-size commitment regardless of how many public inputs the circuit has.
    pub public_inputs_hash: B256,

    /// keccak256 of the raw Binius64 Proof bytes.
    pub proof_hash: B256,
}

impl PublicInputs {
    /// ABI-encode as `abi.encode(bytes32, bytes32, bytes32)`.
    pub fn abi_encode(&self) -> Vec<u8> {
        use alloy_sol_types::SolValue;
        (self.circuit_id, self.public_inputs_hash, self.proof_hash).abi_encode()
    }

    pub fn abi_decode(bytes: &[u8]) -> Result<Self, alloy_sol_types::Error> {
        use alloy_sol_types::SolValue;
        let (circuit_id, public_inputs_hash, proof_hash) =
            <(B256, B256, B256)>::abi_decode(bytes, true)?;
        Ok(Self { circuit_id, public_inputs_hash, proof_hash })
    }
}

// ---------------------------------------------------------------------------
//  Private inputs  (passed to SP1 stdin — never revealed on-chain)
// ---------------------------------------------------------------------------

/// All inputs needed by the guest to run binius-verifier.
/// Public words are stored as raw u64 so this type doesn't depend on binius-core.
/// The guest converts them to `binius_core::word::Word` before calling the verifier.
///
/// SECURITY NOTE: `circuit_id` is NOT a field here — it is computed *inside* the
/// SP1 guest as `keccak256(cs_bytes)`. Accepting it from the prover would allow a
/// malicious prover to bind the SP1 proof to a fake circuit identity.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GuestInputs {
    /// Serialized `binius_core::constraint_system::ConstraintSystem` (binius-utils binary format).
    pub cs_bytes: Vec<u8>,

    /// Serialized `binius_core::constraint_system::Proof` (binius-utils binary format).
    pub proof_bytes: Vec<u8>,

    /// Public witness values as raw u64 (binius `Word(u64)` inner values).
    /// The guest wraps each into `binius_core::word::Word` before calling `Verifier::verify`.
    pub public_words: Vec<u64>,

    /// Log of the inverse rate used when the proof was generated (must match prover).
    /// Typical value: 1 (rate = 1/2).
    pub log_inv_rate: usize,
}

// ---------------------------------------------------------------------------
//  Helper
// ---------------------------------------------------------------------------

pub fn keccak256_bytes(data: &[u8]) -> [u8; 32] {
    use alloy_primitives::keccak256;
    *keccak256(data)
}
