// Binius64 SP1 Guest Program — runs inside SP1's RISC-V zkVM.
//
// 1. Read GuestInputs (cs, proof, public words) from SP1 private stdin
// 2. Compute circuit_id = keccak256(cs_bytes) — INSIDE the guest (security critical)
// 3. Deserialize ConstraintSystem + Proof (binius-utils binary format)
// 4. Setup Verifier<StdDigest(SHA-256), StdCompression>
// 5. Run full verifier: sumcheck → ring-switch → BaseFold/FRI → Merkle paths
// 6. Commit (circuitId, publicInputsHash, proofHash) to SP1 stdout → 96 bytes on-chain
//
// SECURITY: circuit_id is computed from cs_bytes inside the zkVM, not taken from the
// prover input. This cryptographically binds the SP1 proof to the specific circuit that
// was verified. A prover cannot forge a circuit_id for a different circuit.
#![no_main]
sp1_zkvm::entrypoint!(main);

use binius64_sp1_common::{GuestInputs, PublicInputs, keccak256_bytes};
use alloy_primitives::B256;

use binius_core::constraint_system::{ConstraintSystem, Proof};
use binius_core::word::Word;
use binius_hash::{StdCompression, StdDigest};
use binius_transcript::VerifierTranscript;
use binius_utils::DeserializeBytes;
use binius_verifier::{Verifier, config::StdChallenger};

pub fn main() {
    // -------------------------------------------------------------------------
    // Step 1: Read private inputs.
    // -------------------------------------------------------------------------
    let inputs: GuestInputs = sp1_zkvm::io::read::<GuestInputs>();

    // -------------------------------------------------------------------------
    // Step 2 (SECURITY CRITICAL): Compute circuit_id from the constraint system
    //         bytes — inside the zkVM, before anything else.
    //
    //         This guarantees that the committed circuit_id is always exactly
    //         keccak256(cs_bytes) — it cannot be forged by the prover because the
    //         entire execution (including this hash) is covered by the SP1 proof.
    //
    //         On-chain: Binius64SP1Verifier.sol checks that publicValues.circuitId
    //         matches a registered circuit, giving the protocol control over which
    //         circuits are accepted.
    // -------------------------------------------------------------------------
    let circuit_id = keccak256_bytes(&inputs.cs_bytes);

    // -------------------------------------------------------------------------
    // Step 3: Deserialize ConstraintSystem and Proof.
    //         binius-utils DeserializeBytes gives us canonical binary decoding.
    // -------------------------------------------------------------------------
    let cs = ConstraintSystem::deserialize(&mut inputs.cs_bytes.as_slice())
        .expect("Failed to deserialize ConstraintSystem");

    let proof = Proof::deserialize(&mut inputs.proof_bytes.as_slice())
        .expect("Failed to deserialize Proof");

    // -------------------------------------------------------------------------
    // Step 4: Setup the verifier.
    //         StdVerifier = Verifier<StdDigest (SHA-256), StdCompression>
    //         This derives the Merkle tree parameters from the constraint system.
    // -------------------------------------------------------------------------
    let verifier: Verifier<StdDigest, StdCompression> =
        Verifier::setup(cs, inputs.log_inv_rate, StdCompression::default())
            .expect("Failed to setup Verifier");

    // -------------------------------------------------------------------------
    // Step 5: Run the complete Binius64 verifier.
    //         Internally runs:
    //           - Fiat-Shamir transcript (StdChallenger / SHA-256)
    //           - Sumcheck protocol (AND, SHIFT, MUL reductions)
    //           - Ring-switch reduction (GF(2^128) → GF(2^8))
    //           - BaseFold / FRI proximity test
    //           - Binary Merkle authentication paths
    // -------------------------------------------------------------------------
    let (proof_data, _) = proof.into_owned();
    let mut transcript = VerifierTranscript::new(StdChallenger::default(), proof_data);

    // Convert raw u64 values to binius Word newtype
    let public_words: Vec<Word> = inputs.public_words.iter().map(|&v| Word(v)).collect();

    verifier
        .verify(public_words.as_slice(), &mut transcript)
        .expect("Binius64 verification failed");

    transcript
        .finalize()
        .expect("Transcript not fully consumed after verification");

    // -------------------------------------------------------------------------
    // Step 6: Commit public outputs.
    //         96 bytes: (circuitId || publicInputsHash || proofHash)
    //         Decoded by Binius64SP1Verifier.sol as three bytes32 values.
    //
    //         circuit_id is committed here — it was derived from cs_bytes above,
    //         not from prover input, so it is cryptographically authenticated.
    // -------------------------------------------------------------------------
    let proof_hash = keccak256_bytes(&inputs.proof_bytes);

    // Commit to a hash of the public words so on-chain size is fixed at 32 bytes
    // regardless of how many public words the circuit has.
    let pub_words_bytes: Vec<u8> = inputs.public_words.iter()
        .flat_map(|w| w.to_le_bytes())
        .collect();
    let public_inputs_hash = keccak256_bytes(&pub_words_bytes);

    let public_out = PublicInputs {
        circuit_id:         B256::from(circuit_id),
        public_inputs_hash: B256::from(public_inputs_hash),
        proof_hash:         B256::from(proof_hash),
    };

    sp1_zkvm::io::commit_slice(&public_out.abi_encode());
}
