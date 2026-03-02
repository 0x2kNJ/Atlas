// Binius64 Envelope Circuit Benchmark
//
// Measures real wall-clock proving times for the three envelope circuits.
// Does NOT use SP1 simulation — runs the native binius64 prover directly.
//
// Usage:
//   cargo run --release --bin bench
//   cargo run --release --bin bench -- --log-inv-rate 0   # fastest (largest proof)
//   cargo run --release --bin bench -- --log-inv-rate 2   # slowest (smallest proof)
//
// Each circuit uses DoubleSha256 (SHA256∘SHA256), which is ~1.5× more SHA256 rounds
// than a single-SHA256 circuit would use. Divide proof times by ~1.5 for single-SHA256 estimate.
//
// Circuit          SHA256 rounds  Notes
// Encumber         66             2 commitments + nullifier + 20-deep Merkle path
// Spend            69             + output commitment
// Settle           69             (same structure as Spend, different nullifier domain)

use std::time::Instant;

use anyhow::Result;
use binius_examples::{StdProver, StdVerifier, setup_sha256};
use binius_frontend::CircuitBuilder;
use binius_core::constraint_system::ValueVec;
use binius_transcript::{ProverTranscript, VerifierTranscript};
use binius_verifier::config::StdChallenger;
use envelope_circuits::{
    compliance::{ComplianceCircuit, ComplianceInstance, MAX_N},
    encumber::{EncumberCircuit, EncumberInstance},
    settle::SettleCircuit,
    spend::SpendCircuit,
};

const N_PROVE_RUNS: usize = 5;

fn main() -> Result<()> {
    let log_inv_rate = std::env::args()
        .position(|a| a == "--log-inv-rate")
        .and_then(|i| std::env::args().nth(i + 1))
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(1);

    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::WARN)
        .init();

    println!("Binius64 Envelope Circuit Benchmarks");
    println!("log_inv_rate = {}  (rate = 1/{})", log_inv_rate, 1u32 << log_inv_rate);
    println!("Hash: DoubleSha256 (SHA256²)");
    println!("Prove runs: {} (median reported)\n", N_PROVE_RUNS);

    println!(
        "{:<24} | {:>10} | {:>10} | {:>10} | {:>12} | {:>8}",
        "Circuit", "Setup", "Prove", "Verify", "Proof size", "SHA256 rds"
    );
    println!("{}", "-".repeat(90));

    bench_encumber(log_inv_rate)?;
    bench_spend(log_inv_rate)?;
    bench_settle(log_inv_rate)?;
    bench_compliance(log_inv_rate, MAX_N)?;

    println!("\nNotes:");
    println!("  Setup   = one-time key collection (cache with KeyCollection for production)");
    println!("  Prove   = per-proof wall-clock (median of {} runs)", N_PROVE_RUNS);
    println!("  Verify  = verifier time (before SP1 wrapping, happens on relay server)");
    println!("  Compliance: N={} active receipts, DoubleSHA256 rolling root chain", MAX_N);
    println!("  SHA256 rounds: 4 per receipt (3 inner for 160B + 1 outer) × {} = {}", MAX_N, 4 * MAX_N);

    Ok(())
}

fn prove_and_time(
    prover: &StdProver,
    witness: ValueVec,
) -> Result<(std::time::Duration, Vec<u8>)> {
    let t = Instant::now();
    let challenger = StdChallenger::default();
    let mut pt = ProverTranscript::new(challenger);
    prover.prove(witness, &mut pt)?;
    let elapsed = t.elapsed();
    let proof_bytes = pt.finalize();
    Ok((elapsed, proof_bytes))
}

fn verify_and_time(
    verifier: &StdVerifier,
    witness_public: &[binius_core::word::Word],
    proof_bytes: Vec<u8>,
) -> Result<std::time::Duration> {
    let t = Instant::now();
    let challenger = StdChallenger::default();
    let mut vt = VerifierTranscript::new(challenger, proof_bytes);
    verifier.verify(witness_public, &mut vt)?;
    vt.finalize()?;
    Ok(t.elapsed())
}

fn bench_encumber(log_inv_rate: usize) -> Result<()> {
    // Build circuit
    let mut builder = CircuitBuilder::new();
    let circuit = EncumberCircuit::build(&mut builder);
    let built = builder.build();
    let cs = built.constraint_system().clone();

    // Setup (one-time)
    let t_setup = Instant::now();
    let (verifier, prover) = setup_sha256(cs, log_inv_rate, None)?;
    let setup_time = t_setup.elapsed();

    // Populate witness
    let inst = EncumberInstance::test_instance();
    let mut filler = built.new_witness_filler();
    circuit.populate(&mut filler, inst.note_value, inst.note_rand, inst.owner_pk, inst.collateral_amount);
    built.populate_wire_witness(&mut filler)?;
    let witness = filler.into_value_vec();

    // Prove N times, take median
    let mut prove_times = Vec::new();
    let mut proof_size = 0usize;
    let mut last_proof = Vec::new();
    for _ in 0..N_PROVE_RUNS {
        let (t, proof) = prove_and_time(&prover, witness.clone())?;
        proof_size = proof.len();
        last_proof = proof;
        prove_times.push(t);
    }
    prove_times.sort();
    let prove_median = prove_times[N_PROVE_RUNS / 2];

    // Verify
    let verify_time = verify_and_time(&verifier, witness.public(), last_proof)?;

    println!(
        "{:<24} | {:>10} | {:>10} | {:>10} | {:>9} KB | {:>8}",
        "Encumber",
        format_dur(setup_time), format_dur(prove_median), format_dur(verify_time),
        proof_size / 1024, 66,
    );
    Ok(())
}

fn bench_compliance(log_inv_rate: usize, n_active: usize) -> Result<()> {
    let label = format!("Compliance (N={})", n_active);

    // Build circuit
    let mut builder = CircuitBuilder::new();
    let circuit = ComplianceCircuit::build(&mut builder);
    let built = builder.build();
    let cs = built.constraint_system().clone();

    // Setup (one-time)
    let t_setup = Instant::now();
    let (verifier, prover) = setup_sha256(cs, log_inv_rate, None)?;
    let setup_time = t_setup.elapsed();

    // Populate witness
    let inst = ComplianceInstance::test_instance(n_active);
    let mut filler = built.new_witness_filler();
    circuit.populate(&mut filler, &inst);
    built.populate_wire_witness(&mut filler)?;
    let witness = filler.into_value_vec();

    // Prove N times, take median
    let mut prove_times = Vec::new();
    let mut proof_size = 0usize;
    let mut last_proof = Vec::new();
    for _ in 0..N_PROVE_RUNS {
        let (t, proof) = prove_and_time(&prover, witness.clone())?;
        proof_size = proof.len();
        last_proof = proof;
        prove_times.push(t);
    }
    prove_times.sort();
    let prove_median = prove_times[N_PROVE_RUNS / 2];

    // Verify
    let verify_time = verify_and_time(&verifier, witness.public(), last_proof)?;

    let sha256_rounds = 4 * MAX_N; // 4 rounds per receipt × MAX_N slots
    println!(
        "{:<24} | {:>10} | {:>10} | {:>10} | {:>9} KB | {:>8}",
        label,
        format_dur(setup_time), format_dur(prove_median), format_dur(verify_time),
        proof_size / 1024, sha256_rounds,
    );
    Ok(())
}

fn bench_spend(log_inv_rate: usize) -> Result<()> {
    let mut builder = CircuitBuilder::new();
    let circuit = SpendCircuit::build(&mut builder);
    let built = builder.build();
    let cs = built.constraint_system().clone();

    let t_setup = Instant::now();
    let (verifier, prover) = setup_sha256(cs, log_inv_rate, None)?;
    let setup_time = t_setup.elapsed();

    let mut filler = built.new_witness_filler();
    circuit.populate(
        &mut filler,
        100_000_000, [0x42u8; 32], [0x11u8; 32],
        90_000_000,  [0x55u8; 32], [0x11u8; 32],
    );
    built.populate_wire_witness(&mut filler)?;
    let witness = filler.into_value_vec();

    let mut prove_times = Vec::new();
    let mut proof_size = 0usize;
    let mut last_proof = Vec::new();
    for _ in 0..N_PROVE_RUNS {
        let (t, proof) = prove_and_time(&prover, witness.clone())?;
        proof_size = proof.len();
        last_proof = proof;
        prove_times.push(t);
    }
    prove_times.sort();

    let verify_time = verify_and_time(&verifier, witness.public(), last_proof)?;

    println!(
        "{:<24} | {:>10} | {:>10} | {:>10} | {:>9} KB | {:>8}",
        "Spend",
        format_dur(setup_time), format_dur(prove_times[N_PROVE_RUNS / 2]), format_dur(verify_time),
        proof_size / 1024, 69,
    );
    Ok(())
}

fn bench_settle(log_inv_rate: usize) -> Result<()> {
    let mut builder = CircuitBuilder::new();
    let circuit = SettleCircuit::build(&mut builder);
    let built = builder.build();
    let cs = built.constraint_system().clone();

    let t_setup = Instant::now();
    let (verifier, prover) = setup_sha256(cs, log_inv_rate, None)?;
    let setup_time = t_setup.elapsed();

    let mut filler = built.new_witness_filler();
    circuit.populate(
        &mut filler,
        100_000_000, [0x42u8; 32], [0x11u8; 32],
        24_000_000,  [0xAAu8; 32], [0x11u8; 32],
    );
    built.populate_wire_witness(&mut filler)?;
    let witness = filler.into_value_vec();

    let mut prove_times = Vec::new();
    let mut proof_size = 0usize;
    let mut last_proof = Vec::new();
    for _ in 0..N_PROVE_RUNS {
        let (t, proof) = prove_and_time(&prover, witness.clone())?;
        proof_size = proof.len();
        last_proof = proof;
        prove_times.push(t);
    }
    prove_times.sort();

    let verify_time = verify_and_time(&verifier, witness.public(), last_proof)?;

    println!(
        "{:<24} | {:>10} | {:>10} | {:>10} | {:>9} KB | {:>8}",
        "Settle",
        format_dur(setup_time), format_dur(prove_times[N_PROVE_RUNS / 2]), format_dur(verify_time),
        proof_size / 1024, 69,
    );
    Ok(())
}

fn format_dur(d: std::time::Duration) -> String {
    let ms = d.as_secs_f64() * 1000.0;
    if ms >= 1000.0 {
        format!("{:.2}s", ms / 1000.0)
    } else if ms >= 1.0 {
        format!("{:.1}ms", ms)
    } else {
        format!("{:.2}ms", ms)
    }
}
