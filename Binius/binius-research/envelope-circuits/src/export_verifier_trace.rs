// export-verifier-trace: Run the first few steps of the real binius64 verifier
// and export the intermediate transcript state / challenge values.
//
// This lets us validate the Solidity verifier matches at each step.
//
// Usage:
//   cargo run --release --bin export-verifier-trace

use anyhow::Result;
use binius_examples::setup_sha256;
use binius_frontend::CircuitBuilder;
use binius_transcript::{ProverTranscript, VerifierTranscript};
use binius_transcript::fiat_shamir::CanSample;
use binius_verifier::config::StdChallenger;
use binius_field::BinaryField128bGhash as B128;
use envelope_circuits::encumber::{EncumberCircuit, EncumberInstance};

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::WARN)
        .with_writer(std::io::stderr)
        .init();

    eprintln!("Building circuit and generating proof...");

    let log_inv_rate = 1usize;

    let mut builder = CircuitBuilder::new();
    let circuit = EncumberCircuit::build(&mut builder);
    let built = builder.build();
    let cs = built.constraint_system().clone();

    let (verifier, prover) = setup_sha256(cs, log_inv_rate, None)?;

    let inst = EncumberInstance::test_instance();
    let mut filler = built.new_witness_filler();
    circuit.populate(&mut filler, inst.note_value, inst.note_rand, inst.owner_pk, inst.collateral_amount);
    built.populate_wire_witness(&mut filler)?;
    let witness = filler.into_value_vec();

    let public_words: Vec<u64> = witness.public().iter().map(|w| w.0).collect();

    // Generate proof
    let challenger = StdChallenger::default();
    let mut pt = ProverTranscript::new(challenger);
    prover.prove(witness.clone(), &mut pt)?;
    let proof_bytes = pt.finalize();

    eprintln!("Proof: {} bytes", proof_bytes.len());
    eprintln!("Public inputs: {} words", public_words.len());

    // Now run the verifier step-by-step to extract intermediate state
    let challenger = StdChallenger::default();
    let mut vt = VerifierTranscript::new(challenger, proof_bytes.clone());

    // Step 0: Observe public inputs
    vt.observe().write_slice(witness.public());
    eprintln!("After observing public inputs:");

    // Step 1: Read commitment (first 32 bytes from message)
    let mut commitment = [0u8; 32];
    vt.message().read_bytes(&mut commitment);
    println!("commitment: {}", hex::encode(&commitment));

    // After reading commitment, sample the first challenge
    let first_challenge: B128 = vt.sample();
    println!("first_challenge_after_commitment: 0x{:032x}", u128::from(first_challenge));

    // Print public inputs (first 5) for reference
    println!("n_public_words: {}", public_words.len());
    for (i, w) in public_words.iter().take(5).enumerate() {
        println!("public_word[{}]: 0x{:016x}", i, w);
    }

    // Print the first 64 bytes of the proof for verification
    println!("proof_first_64_bytes: {}", hex::encode(&proof_bytes[..64]));

    // Also verify the full proof works
    let challenger2 = StdChallenger::default();
    let mut vt2 = VerifierTranscript::new(challenger2, proof_bytes);
    verifier.verify(witness.public(), &mut vt2)?;
    vt2.finalize()?;
    println!("full_verification: OK");

    Ok(())
}
