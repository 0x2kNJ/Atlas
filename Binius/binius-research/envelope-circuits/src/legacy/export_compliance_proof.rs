// export-compliance-proof: Generate an Atlas compliance proof and export as JSON.
//
// Outputs (stdout, JSON):
//   - circuit_info: circuit name, MAX_N, sha256 rounds
//   - constraint_system_params: layout numbers
//   - proof_hex: raw proof bytes
//   - public_inputs_hex: public words as LE hex
//   - final_rolling_root_hex: the final rolling root (matches on-chain state)
//
// Usage:
//   cargo run --release --bin export-compliance-proof
//   cargo run --release --bin export-compliance-proof -- --n-active 64
//   cargo run --release --bin export-compliance-proof -- --log-inv-rate 2 --n-active 16

use std::io::Write;
use anyhow::Result;
use binius_examples::setup_sha256;
use binius_frontend::CircuitBuilder;
use binius_transcript::{ProverTranscript, VerifierTranscript};
use binius_verifier::config::StdChallenger;
use envelope_circuits::compliance::{
    ComplianceCircuit, ComplianceInstance, MAX_N, build_rolling_msg,
};
use envelope_circuits::common::double_sha256_ref;

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();

    let log_inv_rate = args.windows(2)
        .find(|w| w[0] == "--log-inv-rate")
        .and_then(|w| w[1].parse::<usize>().ok())
        .unwrap_or(1);

    let n_active = args.windows(2)
        .find(|w| w[0] == "--n-active")
        .and_then(|w| w[1].parse::<usize>().ok())
        .unwrap_or(MAX_N);

    assert!(n_active <= MAX_N, "--n-active {} exceeds MAX_N={}", n_active, MAX_N);

    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::WARN)
        .with_writer(std::io::stderr)
        .init();

    eprintln!("Building Compliance circuit (MAX_N={}, n_active={})...", MAX_N, n_active);

    let mut builder = CircuitBuilder::new();
    let circuit = ComplianceCircuit::build(&mut builder);
    let built = builder.build();
    let cs = built.constraint_system().clone();

    let n_witness_words = cs.value_vec_layout.committed_total_len;
    let n_constants = cs.value_vec_layout.n_const;
    let n_public_words = cs.value_vec_layout.n_inout;
    let n_and_constraints = cs.and_constraints.len();
    let n_mul_constraints = cs.mul_constraints.len();

    eprintln!("Constraint system:");
    eprintln!("  n_witness_words:   {}", n_witness_words);
    eprintln!("  n_constants:       {}", n_constants);
    eprintln!("  n_public_words:    {}", n_public_words);
    eprintln!("  n_and_constraints: {}", n_and_constraints);
    eprintln!("  n_mul_constraints: {}", n_mul_constraints);

    eprintln!("Setting up prover/verifier (log_inv_rate={})...", log_inv_rate);
    let (verifier, prover) = setup_sha256(cs, log_inv_rate, None)?;

    let inst = ComplianceInstance::test_instance(n_active);

    let mut filler = built.new_witness_filler();
    circuit.populate(&mut filler, &inst);
    built.populate_wire_witness(&mut filler)?;
    let witness = filler.into_value_vec();

    let public_words: Vec<u64> = witness.public().iter().map(|w| w.0).collect();
    eprintln!("  public_inputs: {} words", public_words.len());

    // Compute expected final root for documentation
    let mut expected_root = inst.capability_hash;
    for r in &inst.active_receipts {
        let msg = build_rolling_msg(&expected_root, r.index, &r.receipt_hash, &r.nullifier, &r.adapter);
        expected_root = double_sha256_ref(&msg);
    }
    for _ in n_active..MAX_N {
        let msg = build_rolling_msg(&expected_root, 0, &[0u8; 32], &[0u8; 32], &[0u8; 32]);
        expected_root = double_sha256_ref(&msg);
    }

    eprintln!("Generating proof...");
    let challenger = StdChallenger::default();
    let mut pt = ProverTranscript::new(challenger);
    prover.prove(witness.clone(), &mut pt)?;
    let proof_bytes = pt.finalize();
    eprintln!("  proof_size: {} bytes ({} KB)", proof_bytes.len(), proof_bytes.len() / 1024);

    eprintln!("Verifying proof...");
    let challenger2 = StdChallenger::default();
    let mut vt = VerifierTranscript::new(challenger2, proof_bytes.clone());
    verifier.verify(witness.public(), &mut vt)?;
    vt.finalize()?;
    eprintln!("  Verification: OK");

    let n_fri_queries = binius_verifier::SECURITY_BITS * (log_inv_rate + 1);
    let sha256_rounds = 4 * MAX_N;

    let proof_hex = hex::encode(&proof_bytes);
    let public_hex: Vec<String> = public_words.iter().map(|w| format!("{:016x}", w)).collect();
    let final_root_hex = hex::encode(&expected_root);

    let json = format!(
        r#"{{
  "circuit_info": {{
    "name": "Compliance",
    "max_n": {},
    "n_active": {},
    "sha256_rounds_estimate": {}
  }},
  "constraint_system_params": {{
    "nWitnessWords": {},
    "nConstants": {},
    "nPublicWords": {},
    "nAndConstraints": {},
    "nMulConstraints": {},
    "logInvRate": {},
    "nFriQueries": {}
  }},
  "proof_hex": "{}",
  "proof_size_bytes": {},
  "public_inputs_hex": [{}],
  "public_inputs_count": {},
  "final_rolling_root_hex": "{}"
}}"#,
        MAX_N,
        n_active,
        sha256_rounds,
        n_witness_words,
        n_constants,
        n_public_words,
        n_and_constraints,
        n_mul_constraints,
        log_inv_rate,
        n_fri_queries,
        proof_hex,
        proof_bytes.len(),
        public_hex.iter().map(|s| format!("\"{}\"", s)).collect::<Vec<_>>().join(", "),
        public_words.len(),
        final_root_hex,
    );

    std::io::stdout().write_all(json.as_bytes())?;
    std::io::stdout().write_all(b"\n")?;

    eprintln!("\nExport complete. Pipe stdout to a file for use with Foundry tests.");
    Ok(())
}
