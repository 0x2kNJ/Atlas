// Atlas Protocol — Compliance Circuit Benchmark (binius m3 API)
//
// Measures real wall-clock proving times for the SHA-256 rolling root chain.
//
// Usage:
//   cargo run --release --bin compliance-bench
//   cargo run --release --bin compliance-bench -- --n-active 64
//   cargo run --release --bin compliance-bench -- --n-blocks 192 --log-inv-rate 1

use std::time::Instant;

use anyhow::Result;
use binius_compute::{ComputeHolder, cpu::alloc::CpuComputeAllocator};
use binius_core::{constraint_system, fiat_shamir::HasherChallenger};
use binius_fast_compute::layer::FastCpuLayerHolder;
use binius_field::{
    PackedExtension, PackedFieldIndexable,
    arch::OptimalUnderlier,
    as_packed_field::PackedType,
    tower::CanonicalTowerFamily,
};
use binius_hal::make_portable_backend;
use binius_hash::groestl::{Groestl256, Groestl256ByteCompression, Groestl256Parallel};
use binius_m3::{
    builder::{
        B1, B32, B128, ConstraintSystem, TableFiller, TableId, TableWitnessSegment, WitnessIndex,
    },
    gadgets::hash::sha256::Sha256,
};
use binius_utils::{checked_arithmetics::log2_ceil_usize, rayon::adjust_thread_pool};
use bytesize::ByteSize;
use clap::{Parser, value_parser};
use tracing_profile::init_tracing;

use envelope_circuits::compliance::{ComplianceInstance, MAX_N, BLOCKS_PER_STEP, TOTAL_BLOCKS};

#[derive(Debug, Parser)]
struct Args {
    /// Number of active receipts (zero-pads to MAX_N).
    #[arg(long, default_value_t = MAX_N as u32, value_parser = value_parser!(u32).range(0..=(MAX_N as i64)))]
    n_active: u32,
    /// Override total SHA-256 blocks (default: MAX_N * 3 = 192).
    #[arg(long)]
    n_blocks: Option<u32>,
    /// Reed-Solomon code rate (log_inv_rate).
    #[arg(long, default_value_t = 1, value_parser = value_parser!(u32).range(1..))]
    log_inv_rate: u32,
}

// ─── Table definition ────────────────────────────────────────────────────────

pub struct ComplianceTable {
    table_id: TableId,
    sha256: Sha256,
}

impl ComplianceTable {
    pub fn new(cs: &mut ConstraintSystem) -> Self {
        let mut table = cs.add_table("Atlas compliance rolling root");
        let sha256 = Sha256::new(&mut table);
        Self {
            table_id: table.id(),
            sha256,
        }
    }
}

impl<P> TableFiller<P> for ComplianceTable
where
    P: PackedFieldIndexable<Scalar = B128> + PackedExtension<B1> + PackedExtension<B32>,
{
    type Event = [u32; 16];

    fn id(&self) -> TableId {
        self.table_id
    }

    fn fill(&self, rows: &[Self::Event], witness: &mut TableWitnessSegment<P>) -> Result<()> {
        self.sha256.populate(witness, rows.iter())?;
        Ok(())
    }
}

// ─── Main ────────────────────────────────────────────────────────────────────

fn main() -> Result<()> {
    const SECURITY_BITS: usize = 100;

    adjust_thread_pool()
        .as_ref()
        .expect("failed to init thread pool");

    let args = Args::parse();
    let _guard = init_tracing().expect("failed to init tracing");

    let n_active = args.n_active as usize;

    // Build compliance witness
    let t_witness = Instant::now();
    let instance = ComplianceInstance::test_instance(n_active);
    let (mut blocks, final_root) = instance.to_sha256_blocks();
    let witness_time = t_witness.elapsed();

    // The m3 SHA-256 example requires a minimum of 128 blocks.
    // Pad to the target size with random blocks.
    let min_blocks = args.n_blocks.map(|n| n as usize).unwrap_or(
        std::cmp::max(TOTAL_BLOCKS.next_power_of_two(), 256)
    );
    let n_blocks = std::cmp::max(min_blocks, blocks.len()).next_power_of_two();

    while blocks.len() < n_blocks {
        blocks.push([0u32; 16]);
    }

    println!("Atlas Compliance Circuit — Binius m3 SHA-256 Benchmark");
    println!("  MAX_N (receipt slots): {}", MAX_N);
    println!("  Active receipts:      {}", n_active);
    println!("  Compliance blocks:    {} ({}×{} per receipt)", TOTAL_BLOCKS, BLOCKS_PER_STEP, MAX_N);
    println!("  Padded table size:    {} (next po2)", n_blocks);
    println!("  log_inv_rate:         {}", args.log_inv_rate);
    println!();

    println!("  Final rolling root: 0x{}", hex::encode(final_root));
    println!("  Witness gen:        {:.1}ms", witness_time.as_secs_f64() * 1000.0);
    println!();

    // Binius m3 setup
    let mut allocator = CpuComputeAllocator::new(
        1 << (12 + log2_ceil_usize(n_blocks) - PackedType::<OptimalUnderlier, B128>::LOG_WIDTH),
    );
    let allocator = allocator.into_bump_allocator();

    let mut cs = ConstraintSystem::new();
    let table = ComplianceTable::new(&mut cs);

    let boundaries = vec![];
    let table_sizes = vec![n_blocks];

    // Fill table witness
    let t_fill = Instant::now();
    let mut witness = WitnessIndex::<PackedType<OptimalUnderlier, B128>>::new(&cs, &allocator);
    witness.fill_table_parallel(&table, &blocks)?;
    let fill_time = t_fill.elapsed();
    println!("  Table fill:         {:.1}ms", fill_time.as_secs_f64() * 1000.0);

    // Compile constraint system
    let t_compile = Instant::now();
    let ccs = cs.compile().unwrap();
    let cs_digest = ccs.digest::<Groestl256>();
    let witness = witness.into_multilinear_extension_index();
    let compile_time = t_compile.elapsed();
    println!("  CS compile:         {:.1}ms", compile_time.as_secs_f64() * 1000.0);

    // Prove
    let t_setup = Instant::now();
    let mut compute_holder = FastCpuLayerHolder::<
        CanonicalTowerFamily,
        PackedType<OptimalUnderlier, B128>,
    >::new(1 << 24, 1 << 30);
    let setup_time = t_setup.elapsed();
    println!("  HAL setup:          {:.1}ms", setup_time.as_secs_f64() * 1000.0);

    let t_prove = Instant::now();
    let proof = constraint_system::prove::<
        _,
        OptimalUnderlier,
        CanonicalTowerFamily,
        Groestl256Parallel,
        Groestl256ByteCompression,
        HasherChallenger<Groestl256>,
        _,
        _,
        _,
    >(
        &mut compute_holder.to_data(),
        &ccs,
        args.log_inv_rate as usize,
        SECURITY_BITS,
        &cs_digest,
        &boundaries,
        &table_sizes,
        witness,
        &make_portable_backend(),
    )?;
    let prove_time = t_prove.elapsed();

    let proof_size = proof.get_proof_size();
    println!("\n  PROVE TIME:         {:.1}ms", prove_time.as_secs_f64() * 1000.0);
    println!("  Proof size:         {}", ByteSize::b(proof_size as u64));

    // Verify
    let t_verify = Instant::now();
    binius_core::constraint_system::verify::<
        OptimalUnderlier,
        CanonicalTowerFamily,
        Groestl256,
        Groestl256ByteCompression,
        HasherChallenger<Groestl256>,
    >(&ccs, args.log_inv_rate as usize, SECURITY_BITS, &cs_digest, &boundaries, proof)?;
    let verify_time = t_verify.elapsed();

    println!("  VERIFY TIME:        {:.1}ms", verify_time.as_secs_f64() * 1000.0);

    println!("\n--- Summary ---");
    println!("  {} SHA-256 blocks (N={} receipts × {} blocks/receipt)",
        n_blocks, MAX_N, BLOCKS_PER_STEP);
    println!("  Witness + Fill:     {:.1}ms", (witness_time + fill_time).as_secs_f64() * 1000.0);
    println!("  Prove:              {:.1}ms", prove_time.as_secs_f64() * 1000.0);
    println!("  Verify:             {:.1}ms", verify_time.as_secs_f64() * 1000.0);
    println!("  Proof size:         {}", ByteSize::b(proof_size as u64));

    Ok(())
}
