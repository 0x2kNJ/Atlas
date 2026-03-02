/// Host proving script: Binius64 proof → SP1 Groth16 proof  (SP1 SDK v6)
///
/// Usage:
///   # Simulate (fast, no real proof — for testing & vkey derivation)
///   cargo run --bin prove -- execute \
///     --cs circuit.cs --proof proof.bin --public public.bin
///
///   # Estimate circuit size and memory requirements before proving
///   cargo run --bin prove -- info --cs circuit.cs --proof proof.bin --public public.bin
///
///   # Generate real Groth16 proof (local CPU, ~10-30s)
///   cargo run --bin prove -- prove \
///     --cs circuit.cs --proof proof.bin --public public.bin --output proof-output.json
///
///   # Via Succinct network prover (~2s, requires SP1_PRIVATE_KEY env var)
///   SP1_PROVER=network cargo run --bin prove -- prove ...
///
///   # Print the vkey hash (constructor arg for Binius64SP1Verifier.sol)
///   cargo run --bin prove -- vkey
///
/// Memory notes:
///   SP1's zkVM has a fixed ~1.875 GB heap limit. Binius circuits that allocate
///   more than this during FRI/Merkle tree construction will panic. Envelope
///   circuits (Encumber/Spend/Settle) with < 32 public words are well within
///   limits. Use `info` subcommand to estimate a circuit's requirements before
///   attempting to prove.

use anyhow::{Context, Result};
use binius64_sp1_common::{GuestInputs, PublicInputs, keccak256_bytes};
use binius_core::constraint_system::{ConstraintSystem, Proof};
use binius_utils::DeserializeBytes;
use clap::{Parser, Subcommand};
use sp1_sdk::{Elf, HashableKey, ProveRequest, Prover, ProverClient, ProvingKey, SP1Stdin};

fn guest_elf() -> Vec<u8> {
    let manifest = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let elf_path = manifest.join(
        "../target/elf-compilation/riscv64im-succinct-zkvm-elf/release/binius64-sp1-program",
    );
    std::fs::read(&elf_path).unwrap_or_else(|_| {
        panic!(
            "Guest ELF not found at {}.\nRun `cargo prove build` in sp1-guest/program/ first.",
            elf_path.display()
        )
    })
}

#[derive(Parser, Debug)]
#[command(name = "prove", about = "Binius64 SP1 prover host")]
struct Args {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Execute in simulation mode (~1s, no real proof generated)
    Execute {
        #[arg(long, help = "Path to serialized ConstraintSystem (.cs file)")]
        cs: String,
        #[arg(long, help = "Path to serialized binius Proof (.bin file)")]
        proof: String,
        #[arg(long, help = "Path to public witness bytes (.bin, 8 bytes per word)")]
        public: String,
        #[arg(long, default_value = "1", help = "log2 inverse rate (default 1 = rate 1/2)")]
        log_inv_rate: usize,
    },
    /// Print circuit info and memory estimate without running the prover
    Info {
        #[arg(long)] cs: String,
        #[arg(long)] proof: String,
        #[arg(long)] public: String,
        #[arg(long, default_value = "1")] log_inv_rate: usize,
    },
    /// Generate real Groth16 proof (local CPU prover)
    Prove {
        #[arg(long)] cs: String,
        #[arg(long)] proof: String,
        #[arg(long)] public: String,
        #[arg(long, default_value = "1")] log_inv_rate: usize,
        #[arg(long, default_value = "proof-output.json")] output: String,
    },
    /// Print the BINIUS64_VKEY (constructor arg for Binius64SP1Verifier.sol)
    Vkey,
}

#[tokio::main]
async fn main() -> Result<()> {
    sp1_sdk::utils::setup_logger();
    let args = Args::parse();
    let elf_bytes = guest_elf();
    let elf = Elf::from(elf_bytes);

    match args.command {
        Command::Execute { cs, proof, public, log_inv_rate } => {
            let inputs = load_inputs(&cs, &proof, &public, log_inv_rate)?;

            print_circuit_info(&inputs);

            let prover = ProverClient::builder().mock().build().await;
            let mut stdin = SP1Stdin::new();
            stdin.write(&inputs);

            println!("\nExecuting guest (simulation)...");
            let (output, report) = prover.execute(elf, stdin).await
                .map_err(|e| {
                    let msg = e.to_string();
                    if msg.contains("0x78000000") || msg.contains("memory") || msg.contains("heap") {
                        anyhow::anyhow!(
                            "SP1 memory limit exceeded (1.875 GB heap).\n\
                             The Binius verifier allocates FRI/Merkle tables that grow with circuit size.\n\
                             Options:\n\
                             - Use a smaller circuit (fewer constraints, fewer public words)\n\
                             - Increase log_inv_rate (--log-inv-rate 2) to reduce proof size at the cost of slower verification\n\
                             - For envelope circuits the limit is typically not reached with < 64 public words\n\
                             Raw error: {}", msg
                        )
                    } else {
                        anyhow::anyhow!("Execution failed: {}", msg)
                    }
                })?;

            println!("  Cycles:             {}", report.total_instruction_count());
            let cycles = report.total_instruction_count();
            println!("  Est. prove time:    ~{}s (CPU prover)", cycles / 50_000_000 + 1);
            println!("  Est. network time:  ~{}s (Succinct network)", std::cmp::max(10, cycles / 500_000_000));

            let pub_out = PublicInputs::abi_decode(output.as_slice())?;
            println!("\nPublic outputs (will be committed on-chain):");
            println!("  circuit_id:         {}", pub_out.circuit_id);
            println!("  public_inputs_hash: {}", pub_out.public_inputs_hash);
            println!("  proof_hash:         {}", pub_out.proof_hash);

            // Show the expected circuit_id (precomputed from cs_bytes on host, same as guest)
            let expected_cid = keccak256_bytes(&std::fs::read(&cs)?);
            println!("\nExpected circuit_id: 0x{}", hex::encode(expected_cid));
            println!("Match: {}", pub_out.circuit_id.as_slice() == expected_cid);
        }

        Command::Info { cs, proof, public, log_inv_rate } => {
            let inputs = load_inputs(&cs, &proof, &public, log_inv_rate)?;
            let circuit_id = keccak256_bytes(&inputs.cs_bytes);

            println!("=== Circuit Info ===");
            println!("  CS bytes:           {} bytes ({:.1} KB)", inputs.cs_bytes.len(), inputs.cs_bytes.len() as f64 / 1024.0);
            println!("  Proof bytes:        {} bytes ({:.1} KB)", inputs.proof_bytes.len(), inputs.proof_bytes.len() as f64 / 1024.0);
            println!("  Public words:       {}", inputs.public_words.len());
            println!("  log_inv_rate:       {}", inputs.log_inv_rate);
            println!("  Circuit ID:         0x{}", hex::encode(circuit_id));

            // Heuristic memory estimate: binius FRI tables scale as O(proof_size * log_inv_rate)
            // Measured: subset-sum (5 words, 1KB proof) → 50 MB; SHA256 (128 words, 200KB proof) → 2.5 GB
            let est_mb = (inputs.proof_bytes.len() as f64 / 1024.0) * 12.5 * (1 << inputs.log_inv_rate) as f64;
            println!("\n  Est. peak memory:   ~{:.0} MB", est_mb);
            if est_mb > 1700.0 {
                println!("  WARNING: Estimated memory exceeds SP1's 1.875 GB heap limit.");
                println!("  This circuit may fail during execution. Consider reducing log_inv_rate.");
            } else {
                println!("  Memory: within SP1 limit (1.875 GB).");
            }

            println!("\n  Register this circuitId on-chain:");
            println!("  cast send <VERIFIER_ADDR> 'registerCircuit(bytes32)' 0x{}", hex::encode(circuit_id));
        }

        Command::Prove { cs, proof, public, log_inv_rate, output } => {
            let inputs = load_inputs(&cs, &proof, &public, log_inv_rate)?;

            print_circuit_info(&inputs);

            let prover = ProverClient::builder().cpu().build().await;
            let pk = prover.setup(elf.clone()).await?;
            println!("\nBINIUS64_VKEY: {}", pk.verifying_key().bytes32());

            let mut stdin = SP1Stdin::new();
            stdin.write(&inputs);

            println!("\nGenerating Groth16 proof (this takes ~10-30s on CPU)...");
            let proof_result = prover.prove(&pk, stdin).groth16().await?;
            println!("Done.");

            let public_values = proof_result.public_values.to_vec();
            let proof_bytes = proof_result.bytes();

            prover.verify(&proof_result, &pk.verifying_key(), None)?;
            println!("Local verification passed.");

            let pub_out = PublicInputs::abi_decode(&public_values)?;
            let out = serde_json::json!({
                "vkey": pk.verifying_key().bytes32().to_string(),
                "publicValues": format!("0x{}", hex::encode(&public_values)),
                "proofBytes":   format!("0x{}", hex::encode(&proof_bytes)),
                "decoded": {
                    "circuitId":         pub_out.circuit_id.to_string(),
                    "publicInputsHash":  pub_out.public_inputs_hash.to_string(),
                    "proofHash":         pub_out.proof_hash.to_string(),
                }
            });
            std::fs::write(&output, serde_json::to_string_pretty(&out)?)?;
            println!("Output → {}", output);

            println!("\n=== Submit on-chain ===");
            println!("# 1. Register circuit (one-time, owner only):");
            println!("cast send <VERIFIER_ADDR> 'registerCircuit(bytes32)' {}",
                pub_out.circuit_id);
            println!("\n# 2. Submit proof:");
            println!("cast send <VERIFIER_ADDR> 'verify(bytes,bytes)' {} {}",
                out["publicValues"], out["proofBytes"]);
            println!("\n# Or atomic verify+call (e.g. enforce an envelope):");
            println!("cast send <VERIFIER_ADDR> 'verifyAndCall(bytes,bytes,address,bytes)' {} {} <ENVELOPE_ADDR> <CALLDATA>",
                out["publicValues"], out["proofBytes"]);
        }

        Command::Vkey => {
            // mock prover is enough to derive the vkey — it only hashes the ELF
            let prover = ProverClient::builder().mock().build().await;
            let pk = prover.setup(elf).await?;
            println!("{}", pk.verifying_key().bytes32());
        }
    }
    Ok(())
}

fn print_circuit_info(inputs: &GuestInputs) {
    let circuit_id = keccak256_bytes(&inputs.cs_bytes);
    println!("=== Circuit ===");
    println!("  circuit_id:  0x{}", hex::encode(circuit_id));
    println!("  cs size:     {:.1} KB", inputs.cs_bytes.len() as f64 / 1024.0);
    println!("  proof size:  {:.1} KB", inputs.proof_bytes.len() as f64 / 1024.0);
    println!("  pub words:   {}", inputs.public_words.len());
    println!("  log_inv_rate:{}", inputs.log_inv_rate);
}

fn load_inputs(
    cs_path: &str, proof_path: &str, public_path: &str,
    log_inv_rate: usize,
) -> Result<GuestInputs> {
    let cs_bytes    = std::fs::read(cs_path)
        .with_context(|| format!("reading constraint system from '{cs_path}'"))?;
    let proof_bytes = std::fs::read(proof_path)
        .with_context(|| format!("reading proof from '{proof_path}'"))?;
    let public_bytes = std::fs::read(public_path)
        .with_context(|| format!("reading public inputs from '{public_path}'"))?;

    // Validate formats eagerly on the host — clearer errors than a guest panic
    ConstraintSystem::deserialize(&mut cs_bytes.as_slice())
        .with_context(|| format!("'{cs_path}' is not a valid serialized ConstraintSystem"))?;
    Proof::deserialize(&mut proof_bytes.as_slice())
        .with_context(|| format!("'{proof_path}' is not a valid serialized binius Proof"))?;

    anyhow::ensure!(
        public_bytes.len() % 8 == 0,
        "'{public_path}' size ({} bytes) is not a multiple of 8 — each public word is 8 bytes (u64 LE)",
        public_bytes.len()
    );
    let public_words: Vec<u64> = public_bytes
        .chunks_exact(8)
        .map(|c| u64::from_le_bytes(c.try_into().unwrap()))
        .collect();

    Ok(GuestInputs { cs_bytes, proof_bytes, public_words, log_inv_rate })
}
