// run-trace: Run the full binius64 verifier and capture TRACE output from the patched library.
// The binius verify_iop has been patched to emit [TRACE] lines to stderr.

use anyhow::Result;
use binius_examples::setup_sha256;
use binius_frontend::CircuitBuilder;
use binius_verifier::config::StdChallenger;
use binius_core::word::Word;
use envelope_circuits::encumber::{EncumberCircuit, EncumberInstance};

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::ERROR)  // suppress info spans
        .with_writer(std::io::stderr)
        .init();

    let log_inv_rate = 1usize;
    let mut builder = CircuitBuilder::new();
    let circuit = EncumberCircuit::build(&mut builder);
    let built = builder.build();
    let cs = built.constraint_system().clone();

    eprintln!("[INFO] n_and_constraints: {}", cs.n_and_constraints());
    eprintln!("[INFO] n_mul_constraints: {}", cs.n_mul_constraints());

    let (verifier, prover) = setup_sha256(cs.clone(), log_inv_rate, None)?;

    let inst = EncumberInstance::test_instance();
    let mut filler = built.new_witness_filler();
    circuit.populate(&mut filler, inst.note_value, inst.note_rand, inst.owner_pk, inst.collateral_amount);
    built.populate_wire_witness(&mut filler)?;
    let witness = filler.into_value_vec();

    let public_words: Vec<Word> = witness.public().to_vec();
    eprintln!("[INFO] n_public_words: {}", public_words.len());

    // Generate proof
    let challenger = StdChallenger::default();
    let mut pt = binius_transcript::ProverTranscript::new(challenger);
    prover.prove(witness.clone(), &mut pt)?;
    let proof_bytes = pt.finalize();
    eprintln!("[INFO] proof_size: {} bytes", proof_bytes.len());

    // Run full verification (with trace output)
    let challenger = StdChallenger::default();
    let mut vt = binius_transcript::VerifierTranscript::new(challenger, proof_bytes);

    eprintln!("[TRACE] transcript_total_bytes={}", vt.remaining_bytes());
    verifier.verify(&public_words, &mut vt)?;
    eprintln!("[TRACE] verification: OK");
    eprintln!("[TRACE] remaining after verify: {}", vt.remaining_bytes());
    vt.finalize()?;
    eprintln!("[TRACE] finalize: OK (all bytes consumed)");

    Ok(())
}
