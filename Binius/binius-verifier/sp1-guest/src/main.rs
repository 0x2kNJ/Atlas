/// Binius64 SP1 Guest Program
///
/// This program runs inside the SP1 zkVM. It:
///   1. Reads the Binius64 proof and public inputs from SP1's input stream
///   2. Runs the Binius64 verifier (the exact same logic as BinaryFieldLib.sol et al.)
///   3. Commits the public inputs + accept/reject result to SP1's public output stream
///
/// SP1 then wraps this execution in a STARK proof, which is further compressed
/// into a Groth16 proof for on-chain verification.
///
/// On-chain, Binius64SP1Verifier.sol calls SP1VerifierGateway.verifyProof() with:
///   - BINIUS64_VKEY: the hash of this compiled binary (constant for a given version)
///   - publicValues: the abi-encoded PublicInputs committed here
///   - proofBytes:   the Groth16 proof output by `cargo prove --groth16`
///
/// To build:
///   cargo prove build   (inside this directory, with SP1 toolchain installed)
///
/// To prove (development mode, no real proof):
///   cargo prove execute --input input.json
///
/// To prove (production Groth16):
///   cargo prove --groth16 --input input.json
///   # Or use SP1's hosted prover: https://docs.succinct.xyz/generating-proofs/prover-network

#![no_main]
sp1_zkvm::entrypoint!(main);

use serde::{Deserialize, Serialize};

/// Public inputs committed to the SP1 output stream.
/// Must match the `PublicInputs` struct in Binius64SP1Verifier.sol (ABI-encoded).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PublicInputs {
    /// Identifies the circuit/constraint system. keccak256 of the circuit spec.
    pub circuit_id: [u8; 32],
    /// The public witness values (claimed inputs/outputs of the proven computation)
    pub public_inputs: Vec<[u8; 32]>,
    /// keccak256 of the raw binius64 proof bytes (for on-chain reference)
    pub proof_hash: [u8; 32],
}

/// Private inputs read from SP1's input stream (not revealed on-chain).
#[derive(Debug, Deserialize)]
pub struct GuestInputs {
    /// The Binius64 proof bytes (serialized binius64::Proof)
    pub proof: Vec<u8>,
    /// The public values (matches PublicInputs.public_inputs)
    pub public_inputs: Vec<[u8; 32]>,
    /// The circuit identifier
    pub circuit_id: [u8; 32],
}

pub fn main() {
    // -------------------------------------------------------------------------
    // Step 1: Read private inputs from SP1's input stream.
    // These are NOT revealed on-chain — only the public outputs below are.
    // -------------------------------------------------------------------------
    let inputs: GuestInputs = sp1_zkvm::io::read::<GuestInputs>();

    // -------------------------------------------------------------------------
    // Step 2: Run the Binius64 verifier.
    //
    // This is the computationally expensive part — binary field arithmetic,
    // FRI verification, sumcheck, Merkle proofs. All running in native Rust
    // at full CPU speed (not on EVM), so it takes ~10-30 seconds on modern
    // hardware rather than 71M gas.
    //
    // The binius64 crate's verifier is the canonical reference implementation.
    // Our Solidity code was developed to match it exactly.
    // -------------------------------------------------------------------------
    let verification_result = verify_binius64_proof(&inputs.proof, &inputs.public_inputs);

    // Abort the proof generation if verification fails.
    // SP1 will not produce a valid proof for a panicking execution.
    assert!(verification_result, "Binius64 proof verification failed");

    // -------------------------------------------------------------------------
    // Step 3: Commit public outputs to SP1's output stream.
    // These become the `publicValues` field verified on-chain.
    // The on-chain contract ABI-decodes these to extract the public inputs.
    // -------------------------------------------------------------------------
    let proof_hash = sp1_zkvm::lib::keccak256(&inputs.proof);

    let public_out = PublicInputs {
        circuit_id: inputs.circuit_id,
        public_inputs: inputs.public_inputs,
        proof_hash,
    };

    sp1_zkvm::io::commit(&public_out);
}

/// Runs the Binius64 verifier on the given proof bytes and public inputs.
///
/// In production, this calls `binius64::verify(proof, public_inputs)` from the
/// binius64 crate. The proof bytes are deserialized and the full verification
/// pipeline (sumcheck, ring-switching, FRI, Merkle) is executed.
fn verify_binius64_proof(proof_bytes: &[u8], public_inputs: &[[u8; 32]]) -> bool {
    #[cfg(feature = "binius64")]
    {
        use binius64::Proof;

        // Deserialize the proof
        let proof: Proof = match bincode::deserialize(proof_bytes) {
            Ok(p) => p,
            Err(_) => return false,
        };

        // Convert public inputs to binius64's field type (GF(2^128) elements)
        let field_inputs: Vec<binius64::BinaryField128b> = public_inputs
            .iter()
            .map(|bytes| binius64::BinaryField128b::from_bytes(bytes))
            .collect();

        // Run the full verifier
        binius64::verify(&proof, &field_inputs).is_ok()
    }

    #[cfg(feature = "stub")]
    {
        // Stub: always passes. Used for testing the SP1 guest harness
        // without the full binius64 dependency.
        let _ = (proof_bytes, public_inputs);
        true
    }
}
