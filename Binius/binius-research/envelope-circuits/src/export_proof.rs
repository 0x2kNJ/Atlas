// export-proof: Generate a binius64 proof and export it in a format
// consumable by the Solidity Binius64Verifier contract.
//
// Outputs (to stdout as JSON):
//   - constraint_system_params: ConstraintSystemParams struct fields
//   - proof_hex: the raw proof bytes as a hex string
//   - public_inputs_hex: public inputs as u64 LE hex array
//
// Usage:
//   cargo run --release --bin export-proof > proof_data.json
//   cargo run --release --bin export-proof -- --log-inv-rate 2

use std::io::Write;

use anyhow::Result;
use binius_examples::{setup_sha256};
use binius_frontend::CircuitBuilder;
use binius_transcript::{ProverTranscript, VerifierTranscript};
use binius_verifier::config::StdChallenger;
use envelope_circuits::encumber::{EncumberCircuit, EncumberInstance};

fn main() -> Result<()> {
    let log_inv_rate = std::env::args()
        .position(|a| a == "--log-inv-rate")
        .and_then(|i| std::env::args().nth(i + 1))
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(1);

    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::WARN)
        .with_writer(std::io::stderr)
        .init();

    eprintln!("Building Encumber circuit...");
    let mut builder = CircuitBuilder::new();
    let circuit = EncumberCircuit::build(&mut builder);
    let built = builder.build();
    let cs = built.constraint_system().clone();

    // Extract constraint system parameters
    let n_witness_words = cs.value_vec_layout.committed_total_len;
    let n_constants = cs.value_vec_layout.n_const;
    let n_public_words = cs.value_vec_layout.n_inout;
    let n_and_constraints = cs.and_constraints.len();
    let n_mul_constraints = cs.mul_constraints.len();

    eprintln!("Constraint system:");
    eprintln!("  n_witness_words:  {}", n_witness_words);
    eprintln!("  n_constants:      {}", n_constants);
    eprintln!("  n_public_words:   {}", n_public_words);
    eprintln!("  n_and_constraints: {}", n_and_constraints);
    eprintln!("  n_mul_constraints: {}", n_mul_constraints);

    // Setup
    eprintln!("Setting up prover/verifier (log_inv_rate={})...", log_inv_rate);
    let (verifier, prover) = setup_sha256(cs, log_inv_rate, None)?;

    // Populate witness
    let inst = EncumberInstance::test_instance();
    let mut filler = built.new_witness_filler();
    circuit.populate(&mut filler, inst.note_value, inst.note_rand, inst.owner_pk, inst.collateral_amount);
    built.populate_wire_witness(&mut filler)?;
    let witness = filler.into_value_vec();

    // Extract public inputs before proving (they get cloned for verification)
    let public_words: Vec<u64> = witness.public().iter().map(|w| w.0).collect();
    eprintln!("  public_inputs: {} words", public_words.len());

    // Generate proof
    eprintln!("Generating proof...");
    let challenger = StdChallenger::default();
    let mut pt = ProverTranscript::new(challenger);
    prover.prove(witness.clone(), &mut pt)?;
    let proof_bytes = pt.finalize();
    eprintln!("  proof_size: {} bytes ({} KB)", proof_bytes.len(), proof_bytes.len() / 1024);

    // Print FRI params
    let fri_params = verifier.fri_params();
    eprintln!("FRI params:");
    eprintln!("  rs_code.log_dim() = {}", fri_params.rs_code().log_dim());
    eprintln!("  rs_code.log_len() = {}", fri_params.rs_code().log_len());
    eprintln!("  rs_code.log_inv_rate() = {}", fri_params.rs_code().log_inv_rate());
    eprintln!("  log_batch_size = {}", fri_params.log_batch_size());
    eprintln!("  fold_arities = {:?}", fri_params.fold_arities());
    eprintln!("  n_test_queries = {}", fri_params.n_test_queries());
    eprintln!("  index_bits = {}", fri_params.index_bits());
    eprintln!("  rs_code.subspace().dim() = {}", fri_params.rs_code().subspace().dim());
    eprintln!("  rs_code.subspace().basis():");
    for (i, b) in fri_params.rs_code().subspace().basis().iter().enumerate() {
        eprintln!("    beta_{} = 0x{:032x}", i, u128::from(*b));
    }

    // Verify to make sure the proof is valid
    eprintln!("Verifying proof...");
    let challenger = StdChallenger::default();
    let mut vt = VerifierTranscript::new(challenger, proof_bytes.clone());
    verifier.verify(witness.public(), &mut vt)?;
    vt.finalize()?;
    eprintln!("  Verification: OK");

    // Compute FRI query count for the given security level
    let n_fri_queries = binius_verifier::SECURITY_BITS * (log_inv_rate + 1);

    // Output as JSON
    let proof_hex = hex::encode(&proof_bytes);
    let public_hex: Vec<String> = public_words.iter().map(|w| format!("{:016x}", w)).collect();

    let json = format!(
        r#"{{
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
  "public_inputs_count": {}
}}"#,
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
    );

    // Write JSON to stdout
    std::io::stdout().write_all(json.as_bytes())?;
    std::io::stdout().write_all(b"\n")?;

    eprintln!("\nExport complete. Pipe stdout to a file for use with Foundry tests.");
    Ok(())
}
