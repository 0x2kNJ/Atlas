//! Atlas Protocol — Binius64 Compliance Circuit Benchmark
//!
//! Measures end-to-end: circuit build → witness → constraint check → prove → verify.

use std::time::Instant;

use anyhow::Result;
use binius64_compliance::{ComplianceCircuit, ComplianceInstance, MAX_N};
use binius_core::verify::verify_constraints;
use binius_frontend::CircuitBuilder;
use binius_prover::{OptimalPackedB128, Prover, hash::parallel_compression::ParallelCompressionAdaptor};
use binius_transcript::{ProverTranscript, VerifierTranscript};
use binius_verifier::{Verifier, config::StdChallenger, hash::{StdCompression, StdDigest}};

fn main() -> Result<()> {
    let n_active = 4;
    let n_steps = MAX_N;

    println!("Atlas Protocol — Binius64 Compliance Circuit");
    println!("  Steps: {n_steps}, Active receipts: {n_active}");
    println!();

    // 1. Build circuit
    let t = Instant::now();
    let builder = CircuitBuilder::new();
    let cc = ComplianceCircuit::build(&builder, n_steps);
    let circuit = builder.build();
    println!("  Circuit build:     {:>8.1} ms", t.elapsed().as_secs_f64() * 1000.0);

    // 2. Populate witness
    let t = Instant::now();
    let instance = ComplianceInstance::test_instance(n_active);
    let mut witness = circuit.new_witness_filler();
    cc.populate_witness(&instance, &mut witness);
    circuit.populate_wire_witness(&mut witness)?;
    println!("  Witness populate:  {:>8.1} ms", t.elapsed().as_secs_f64() * 1000.0);

    // 3. Verify constraints (debug sanity check)
    let t = Instant::now();
    let cs = circuit.constraint_system();
    let witness_vec = witness.into_value_vec();
    verify_constraints(cs, &witness_vec).map_err(|e| anyhow::anyhow!(e))?;
    println!("  Constraint check:  {:>8.1} ms", t.elapsed().as_secs_f64() * 1000.0);
    println!("  -> Constraints satisfied");

    // 4. Setup prover & verifier (Merkle tree key collection)
    let t = Instant::now();
    let compression = ParallelCompressionAdaptor::new(StdCompression::default());
    let verifier = Verifier::<StdDigest, _>::setup(cs.clone(), 1, StdCompression::default())?;
    let prover = Prover::<OptimalPackedB128, _, StdDigest>::setup(verifier.clone(), compression)?;
    println!("  Prover setup:      {:>8.1} ms", t.elapsed().as_secs_f64() * 1000.0);

    // 5. Prove
    let t = Instant::now();
    let challenger = StdChallenger::default();
    let public_words = witness_vec.public().to_vec();
    let mut prover_transcript = ProverTranscript::new(challenger.clone());
    prover.prove(witness_vec, &mut prover_transcript)?;
    let proof = prover_transcript.finalize();
    let prove_ms = t.elapsed().as_secs_f64() * 1000.0;
    println!("  PROVE:             {:>8.1} ms", prove_ms);
    println!(
        "  Proof size:        {:>8} bytes ({:.1} KiB)",
        proof.len(),
        proof.len() as f64 / 1024.0
    );

    // 6. Verify
    let t = Instant::now();
    let mut verifier_transcript = VerifierTranscript::new(challenger, proof);
    verifier.verify(&public_words, &mut verifier_transcript)?;
    verifier_transcript.finalize()?;
    let verify_ms = t.elapsed().as_secs_f64() * 1000.0;
    println!("  VERIFY:            {:>8.1} ms", verify_ms);

    println!();
    println!("  Proof verified successfully!");
    println!(
        "  Total prove+verify: {:.1} ms",
        prove_ms + verify_ms
    );

    Ok(())
}
