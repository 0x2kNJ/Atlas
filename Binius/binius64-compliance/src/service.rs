//! Atlas Protocol — Binius64 Compliance Proof Service
//!
//! Reads a JSON request from stdin, generates and verifies a Binius64 compliance proof,
//! and writes a JSON response to stdout. Designed to be spawned by the TypeScript SDK.
//!
//! Input JSON:
//! ```json
//! {
//!   "capability_hash": "0xca...",
//!   "receipts": [
//!     { "index": 0, "receipt_hash": "0x10...", "nullifier": "0x20...", "adapter": "0xab..." },
//!     ...
//!   ],
//!   "n_steps": 64
//! }
//! ```
//!
//! Output JSON:
//! ```json
//! {
//!   "success": true,
//!   "final_root": "0x...",
//!   "proof_digest": "0x...",
//!   "proof_size_bytes": 290304,
//!   "prove_ms": 173.4,
//!   "verify_ms": 46.7,
//!   "total_ms": 220.1
//! }
//! ```

use std::io::{self, Read};
use std::time::Instant;

use anyhow::Result;
use binius64_compliance::{
    ActiveReceipt, ComplianceCircuit, ComplianceInstance, MAX_N, compute_full_rolling_root,
};
use binius_core::verify::verify_constraints;
use binius_frontend::CircuitBuilder;
use binius_prover::{OptimalPackedB128, Prover, hash::parallel_compression::ParallelCompressionAdaptor};
use binius_transcript::{ProverTranscript, VerifierTranscript};
use binius_verifier::{Verifier, config::StdChallenger, hash::{StdCompression, StdDigest}};
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
struct Request {
    capability_hash: String,
    receipts: Vec<ReceiptInput>,
    #[serde(default = "default_steps")]
    n_steps: usize,
}

fn default_steps() -> usize {
    MAX_N
}

#[derive(Deserialize)]
struct ReceiptInput {
    index: u64,
    receipt_hash: String,
    nullifier: String,
    adapter: String,
}

#[derive(Serialize)]
struct Response {
    success: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    final_root: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    proof_digest: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    proof_size_bytes: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    prove_ms: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    verify_ms: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    total_ms: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

fn hex_to_bytes32(s: &str) -> Result<[u8; 32]> {
    let s = s.strip_prefix("0x").unwrap_or(s);
    let bytes = hex::decode(s)?;
    let mut out = [0u8; 32];
    let len = bytes.len().min(32);
    out[32 - len..].copy_from_slice(&bytes[..len]);
    Ok(out)
}

fn bytes32_to_hex(b: &[u8; 32]) -> String {
    format!("0x{}", hex::encode(b))
}

fn run(req: Request) -> Result<Response> {
    let capability_hash = hex_to_bytes32(&req.capability_hash)?;

    let active_receipts: Vec<ActiveReceipt> = req
        .receipts
        .iter()
        .map(|r| {
            Ok(ActiveReceipt {
                index: r.index,
                receipt_hash: hex_to_bytes32(&r.receipt_hash)?,
                nullifier: hex_to_bytes32(&r.nullifier)?,
                adapter: hex_to_bytes32(&r.adapter)?,
            })
        })
        .collect::<Result<_>>()?;

    let n_steps = req.n_steps;
    let instance = ComplianceInstance {
        capability_hash,
        active_receipts,
    };

    let final_root = compute_full_rolling_root(
        &instance.capability_hash,
        &instance.active_receipts,
        n_steps,
    );

    // Build circuit
    let builder = CircuitBuilder::new();
    let cc = ComplianceCircuit::build(&builder, n_steps);
    let circuit = builder.build();

    // Populate witness
    let mut witness = circuit.new_witness_filler();
    cc.populate_witness(&instance, &mut witness);
    circuit
        .populate_wire_witness(&mut witness)
        .map_err(|e| anyhow::anyhow!(e))?;

    // Verify constraints
    let cs = circuit.constraint_system();
    let witness_vec = witness.into_value_vec();
    verify_constraints(cs, &witness_vec).map_err(|e| anyhow::anyhow!(e))?;

    // Setup
    let compression = ParallelCompressionAdaptor::new(StdCompression::default());
    let verifier = Verifier::<StdDigest, _>::setup(cs.clone(), 1, StdCompression::default())?;
    let prover = Prover::<OptimalPackedB128, _, StdDigest>::setup(verifier.clone(), compression)?;

    // Prove
    let t_prove = Instant::now();
    let challenger = StdChallenger::default();
    let public_words = witness_vec.public().to_vec();
    let mut prover_transcript = ProverTranscript::new(challenger.clone());
    prover.prove(witness_vec, &mut prover_transcript)?;
    let proof = prover_transcript.finalize();
    let prove_ms = t_prove.elapsed().as_secs_f64() * 1000.0;

    let proof_size = proof.len();

    // keccak256-equivalent digest of the proof for the attestation
    // (using sha256 since we don't have keccak in Rust here — the TS side will
    //  compute keccak256 of the raw proof bytes for the on-chain digest)
    use sha2::{Digest, Sha256};
    let proof_digest_bytes: [u8; 32] = Sha256::digest(&proof).into();

    // Verify
    let t_verify = Instant::now();
    let mut verifier_transcript = VerifierTranscript::new(challenger, proof);
    verifier.verify(&public_words, &mut verifier_transcript)?;
    verifier_transcript.finalize()?;
    let verify_ms = t_verify.elapsed().as_secs_f64() * 1000.0;

    Ok(Response {
        success: true,
        final_root: Some(bytes32_to_hex(&final_root)),
        proof_digest: Some(bytes32_to_hex(&proof_digest_bytes)),
        proof_size_bytes: Some(proof_size),
        prove_ms: Some(prove_ms),
        verify_ms: Some(verify_ms),
        total_ms: Some(prove_ms + verify_ms),
        error: None,
    })
}

fn main() {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).unwrap();

    let response = match serde_json::from_str::<Request>(&input) {
        Ok(req) => match run(req) {
            Ok(resp) => resp,
            Err(e) => Response {
                success: false,
                final_root: None,
                proof_digest: None,
                proof_size_bytes: None,
                prove_ms: None,
                verify_ms: None,
                total_ms: None,
                error: Some(e.to_string()),
            },
        },
        Err(e) => Response {
            success: false,
            final_root: None,
            proof_digest: None,
            proof_size_bytes: None,
            prove_ms: None,
            verify_ms: None,
            total_ms: None,
            error: Some(format!("Invalid JSON input: {e}")),
        },
    };

    println!("{}", serde_json::to_string(&response).unwrap());
}
