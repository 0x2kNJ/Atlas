/// Off-chain verification of a saved proof.
///
/// Usage:
///   cargo run --bin verify-offchain -- --proof-json proof-output.json

use anyhow::Result;
use clap::Parser;
use sp1_sdk::{Elf, HashableKey, Prover, ProverClient, ProvingKey, SP1ProofWithPublicValues};
use binius64_sp1_common::PublicInputs;

fn guest_elf() -> Vec<u8> {
    let manifest = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let elf_path = manifest.join(
        "../target/elf-compilation/riscv64im-succinct-zkvm-elf/release/binius64-sp1-program",
    );
    std::fs::read(&elf_path).unwrap_or_else(|_| {
        panic!(
            "Guest ELF not found. Run `cargo prove build` in sp1-guest/program/ first."
        )
    })
}

#[derive(Parser, Debug)]
#[command(name = "verify-offchain")]
struct Args {
    #[arg(long)]
    proof_json: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let elf = Elf::from(guest_elf());

    let out: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&args.proof_json)?)?;

    let pub_values_hex = out["publicValues"].as_str().unwrap().trim_start_matches("0x");
    let public_values = hex::decode(pub_values_hex)?;

    let prover = ProverClient::builder().mock().build().await;
    let pk = prover.setup(elf).await?;

    let expected_vkey = pk.verifying_key().bytes32().to_string();
    let stored_vkey = out["vkey"].as_str().unwrap();
    if expected_vkey != stored_vkey {
        anyhow::bail!(
            "Vkey mismatch!\n  Built ELF: {}\n  Proof generated with: {}",
            expected_vkey, stored_vkey
        );
    }

    let proof = SP1ProofWithPublicValues::load(&args.proof_json)?;
    prover.verify(&proof, &pk.verifying_key(), None)?;
    println!("Proof verified successfully.");

    let pub_out = PublicInputs::abi_decode(&public_values)?;
    println!("  circuit_id:         {}", pub_out.circuit_id);
    println!("  public_inputs_hash: {}", pub_out.public_inputs_hash);
    println!("  proof_hash:         {}", pub_out.proof_hash);

    Ok(())
}
