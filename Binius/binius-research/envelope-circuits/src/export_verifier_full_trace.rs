// export-verifier-full-trace: Run the full binius64 verifier step-by-step,
// printing byte offsets, read values, and sampled challenges at each protocol stage.
//
// This is the ground truth for implementing the Solidity verifier.
//
// Usage:
//   cargo run --release --bin export-verifier-full-trace

use anyhow::Result;
use binius_examples::setup_sha256;
use binius_frontend::CircuitBuilder;
use binius_transcript::VerifierTranscript;
use binius_transcript::fiat_shamir::CanSample;
use binius_verifier::config::StdChallenger;
use binius_field::{BinaryField128bGhash as B128, AESTowerField8b as B8};
use binius_field::{Field, arithmetic_traits::InvertOrZero};
use binius_utils::checked_arithmetics::{checked_log_2, strict_log_2};
use binius_math::{BinarySubspace, univariate::extrapolate_over_subspace};
use binius_verifier::config::{
    LOG_WORD_SIZE_BITS, PROVER_SMALL_FIELD_ZEROCHECK_CHALLENGES,
};
use binius_verifier::and_reduction::utils::constants::ROWS_PER_HYPERCUBE_VERTEX;
use binius_math::univariate::evaluate_univariate;
use binius_core::word::Word;
use envelope_circuits::encumber::{EncumberCircuit, EncumberInstance};

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::WARN)
        .with_writer(std::io::stderr)
        .init();

    eprintln!("Building circuit...");
    let log_inv_rate = 1usize;
    let mut builder = CircuitBuilder::new();
    let circuit = EncumberCircuit::build(&mut builder);
    let built = builder.build();
    let cs = built.constraint_system().clone();

    let (verifier, prover) = setup_sha256(cs.clone(), log_inv_rate, None)?;

    // Use the PREPARED constraint system (after validate_and_prepare)
    let pcs = verifier.constraint_system();
    eprintln!("Constraint system details (prepared):");
    eprintln!("  n_and_constraints: {}", pcs.n_and_constraints());
    eprintln!("  n_mul_constraints: {}", pcs.n_mul_constraints());
    eprintln!("  committed_total_len: {}", pcs.value_vec_layout.committed_total_len);
    eprintln!("  n_const: {}", pcs.value_vec_layout.n_const);
    eprintln!("  n_inout: {}", pcs.value_vec_layout.n_inout);
    eprintln!("  offset_witness: {}", pcs.value_vec_layout.offset_witness);
    eprintln!("  n_witness: {}", pcs.value_vec_layout.n_witness);
    eprintln!("  n_internal: {}", pcs.value_vec_layout.n_internal);

    let log_n_and = checked_log_2(pcs.n_and_constraints());
    eprintln!("  log_n_and_constraints: {}", log_n_and);
    let log_word_count = strict_log_2(pcs.value_vec_layout.committed_total_len).unwrap();
    let inout_n_vars = strict_log_2(pcs.value_vec_layout.offset_witness).unwrap_or(0);
    eprintln!("  log_word_count: {}", log_word_count);
    eprintln!("  inout_n_vars: {}", inout_n_vars);
    let log_n_mul = checked_log_2(pcs.n_mul_constraints());
    eprintln!("  log_n_mul: {}", log_n_mul);

    let inst = EncumberInstance::test_instance();
    let mut filler = built.new_witness_filler();
    circuit.populate(&mut filler, inst.note_value, inst.note_rand, inst.owner_pk, inst.collateral_amount);
    built.populate_wire_witness(&mut filler)?;
    let witness = filler.into_value_vec();

    let public_words: Vec<Word> = witness.public().to_vec();
    eprintln!("  public words count: {}", public_words.len());

    // Generate proof
    let challenger = StdChallenger::default();
    let mut pt = binius_transcript::ProverTranscript::new(challenger);
    prover.prove(witness.clone(), &mut pt)?;
    let proof_bytes = pt.finalize();
    eprintln!("\nProof: {} bytes ({} KB)", proof_bytes.len(), proof_bytes.len() / 1024);

    let total_proof_bytes = proof_bytes.len();

    // ─── Now trace through verification step by step ────────────────────────

    let challenger = StdChallenger::default();
    let mut vt = VerifierTranscript::new(challenger, proof_bytes.clone());

    macro_rules! offset {
        () => { total_proof_bytes - vt.remaining_bytes() };
    }

    println!("\n=== Binius64 Verifier Protocol Trace ===");
    println!("Total proof bytes: {}", total_proof_bytes);

    // ─── Step 0: Observe public inputs ─────────────────────────────────────
    println!("\n--- Step 0: Observe public inputs ---");
    let before = offset!();
    vt.observe().write_slice(&public_words);
    let after = offset!();
    println!("  bytes consumed: {} (expected 0 - observe only)", after - before);
    println!("  n_public_words: {}", public_words.len());
    println!("  transcript_offset: {}", after);

    // ─── Step 1: Read trace commitment ──────────────────────────────────────
    println!("\n--- Step 1: Trace commitment (32 bytes, message) ---");
    let before = offset!();
    let mut commitment = [0u8; 32];
    let _ = vt.message().read_bytes(&mut commitment);
    let after = offset!();
    println!("  bytes consumed: {}", after - before);
    println!("  commitment: {}", hex::encode(&commitment));
    println!("  transcript_offset: {} -> {}", before, after);

    // ─── Step 2: IntMul reduction ────────────────────────────────────────────
    println!("\n--- Step 2: IntMul reduction ---");
    let n_mul = cs.n_mul_constraints();
    println!("  n_mul_constraints: {}", n_mul);
    let before = offset!();
    if n_mul == 0 {
        println!("  SKIPPED (n_mul=0)");
    } else {
        let log_n_mul = checked_log_2(n_mul);
        println!("  Would run IntMul with log_n_mul={}", log_n_mul);
        // We skip actual IntMul for now - it complicates the trace
    }
    let after = offset!();
    println!("  bytes consumed: {}", after - before);
    println!("  transcript_offset: {} -> {}", before, after);

    // ─── Step 3: AND reduction ───────────────────────────────────────────────
    println!("\n--- Step 3: AND reduction ---");
    let before = offset!();

    // 3a: Sample 15 big-field zerocheck challenges (no proof bytes)
    let big_field_challenges: Vec<B128> = (0..(log_n_and - 3)).map(|_| vt.sample()).collect();
    println!("  3a: Sampled {} big-field zerocheck challenges", big_field_challenges.len());
    for (i, c) in big_field_challenges.iter().enumerate() {
        println!("      big_field_zc[{}]: 0x{:032x}", i, u128::from(*c));
    }

    // 3b: Small-field hardcoded challenges [0x2, 0x4, 0x10]
    let small_field_zc: Vec<B128> = PROVER_SMALL_FIELD_ZEROCHECK_CHALLENGES
        .iter()
        .map(|&c| B128::from(c))
        .collect();
    println!("  3b: Small-field zerocheck challenges:");
    for (i, c) in small_field_zc.iter().enumerate() {
        println!("      small_field_zc[{}]: 0x{:032x}", i, u128::from(*c));
    }

    // Combined: small first, then big
    let all_zc: Vec<B128> = small_field_zc.into_iter().chain(big_field_challenges.into_iter()).collect();
    println!("  3c: Total zerocheck challenges: {}", all_zc.len());

    // 3d: Read 64 univariate extension-domain evaluations (ROWS_PER_HYPERCUBE_VERTEX)
    println!("  3d: Reading {} extension-domain evals from proof", ROWS_PER_HYPERCUBE_VERTEX);
    let offset_before_univariate = offset!();
    let mut univariate_evals: Vec<B128> = Vec::with_capacity(ROWS_PER_HYPERCUBE_VERTEX);
    for _ in 0..ROWS_PER_HYPERCUBE_VERTEX {
        let val: B128 = vt.message().read_scalar().unwrap();
        univariate_evals.push(val);
    }
    let offset_after_univariate = offset!();
    println!("  bytes consumed for univariate evals: {}", offset_after_univariate - offset_before_univariate);
    println!("  first 3 univariate evals: {:?}", univariate_evals[..3].iter().map(|v| format!("0x{:032x}", u128::from(*v))).collect::<Vec<_>>());

    // 3e: Sample z challenge
    let z_challenge: B128 = vt.sample();
    println!("  3e: z_challenge: 0x{:032x}", u128::from(z_challenge));

    // 3f: Build coefficients array (64 zeros + 64 evals) and extrapolate
    let subfield_subspace = BinarySubspace::<B8>::default().isomorphic::<B128>();
    let extended_subspace = subfield_subspace.reduce_dim(LOG_WORD_SIZE_BITS + 1);
    let _domain_subspace = extended_subspace.reduce_dim(LOG_WORD_SIZE_BITS);

    let mut univariate_coeffs = vec![B128::ZERO; 2 * ROWS_PER_HYPERCUBE_VERTEX];
    univariate_coeffs[ROWS_PER_HYPERCUBE_VERTEX..].copy_from_slice(&univariate_evals);
    let sumcheck_claim = extrapolate_over_subspace(&extended_subspace, &univariate_coeffs, z_challenge);
    println!("  3f: sumcheck_claim (extrapolated): 0x{:032x}", u128::from(sumcheck_claim));
    println!("  Extended subspace dim: {}", extended_subspace.dim());
    println!("  Extended subspace size: {}", 1 << extended_subspace.dim());

    // Print ALL extended subspace elements (these are the hardcoded domain elements for Solidity)
    let extended_subspace_vec: Vec<B128> = extended_subspace.iter().collect();
    println!("  Extended subspace size: {}", extended_subspace_vec.len());
    println!("  // Extended subspace elements (hardcode these in Solidity):");
    for (i, e) in extended_subspace_vec.iter().enumerate() {
        println!("  uint256 constant EXT_DOMAIN_{} = 0x{:032x};", i, u128::from(*e));
    }

    // Print the barycentric weight w = (prod_{j=1}^{n-1} domain[j])^{-1}
    let mut w_inv = B128::ONE;
    for j in 1..extended_subspace_vec.len() {
        w_inv = w_inv * extended_subspace_vec[j];
    }
    let w = w_inv.invert_or_zero();
    println!("  // Barycentric weight w:");
    println!("  uint256 constant EXT_DOMAIN_W = 0x{:032x};", u128::from(w));
    println!("  // w_inv = 0x{:032x};", u128::from(w_inv));

    // 3g: Run sumcheck with pre-determined challenges (n_vars = log_n_and, degree=2)
    // NOTE: all_zc is used as the per-round challenges
    // But wait: mlecheck::verify is slightly different from standard sumcheck.
    // It uses ALL the zerocheck challenges as the per-round challenges.
    // The sumcheck has n_vars = all_zc.len() = log_n_and = 18 rounds.
    println!("\n  3g: Running sumcheck ({} rounds, using pre-determined challenges)", all_zc.len());
    let offset_before_sumcheck = offset!();

    // Manually run the sumcheck to trace byte consumption
    let mut current_sum = sumcheck_claim;
    let mut eval_point = Vec::new();
    for (round, &challenge) in all_zc.iter().enumerate() {
        let a: B128 = vt.message().read_scalar().unwrap();
        let b: B128 = vt.message().read_scalar().unwrap();
        let c: B128 = vt.message().read_scalar().unwrap();
        // Check: a + (a+b+c) = a + a + b + c = b+c = current_sum
        let sum_check = b + c;
        let matches = sum_check == current_sum;
        if round < 3 || !matches {
            println!("      Round {}: a=0x{:.8x} b=0x{:.8x} c=0x{:.8x} sum_check={} challenge=0x{:.8x}",
                round,
                u128::from(a), u128::from(b), u128::from(c), matches, u128::from(challenge));
        }
        // Evaluate at challenge: a + b*r + c*r^2
        current_sum = a + b * challenge + c * (challenge * challenge);
        eval_point.push(challenge);
    }
    let offset_after_sumcheck = offset!();
    println!("  Sumcheck bytes consumed: {}", offset_after_sumcheck - offset_before_sumcheck);
    println!("  Sumcheck final eval: 0x{:032x}", u128::from(current_sum));

    // 3h: Read [a_eval, b_eval, c_eval]
    let a_eval: B128 = vt.message().read_scalar().unwrap();
    let b_eval: B128 = vt.message().read_scalar().unwrap();
    let c_eval: B128 = vt.message().read_scalar().unwrap();
    println!("\n  3h: a_eval: 0x{:032x}", u128::from(a_eval));
    println!("      b_eval: 0x{:032x}", u128::from(b_eval));
    println!("      c_eval: 0x{:032x}", u128::from(c_eval));

    // Check: a*b - c = current_sum
    let and_check = a_eval * b_eval + c_eval;  // a*b - c = a*b XOR c in GF(2)
    println!("      a*b+c: 0x{:032x} (should equal sumcheck_eval: 0x{:032x})", u128::from(and_check), u128::from(current_sum));

    let after_and = offset!();
    println!("\n  AND reduction total bytes: {}", after_and - before);
    println!("  transcript_offset after AND: {}", after_and);

    // ─── Step 4: Shift reduction ─────────────────────────────────────────────
    println!("\n--- Step 4: Shift reduction ---");
    let before_shift = offset!();

    // 4a: Sample bitand_lambda, intmul_lambda
    let bitand_lambda: B128 = vt.sample();
    let intmul_lambda: B128 = vt.sample();
    println!("  bitand_lambda: 0x{:032x}", u128::from(bitand_lambda));
    println!("  intmul_lambda: 0x{:032x}", u128::from(intmul_lambda));

    // 4b: Compute eval = bitand_data.batched_eval(bitand_lambda) + intmul_data.batched_eval(intmul_lambda)
    // batched_eval(lambda) = lambda * evaluate_univariate([a,b,c], lambda)
    // evaluate_univariate([a,b,c], lambda) = a + b*lambda + c*lambda^2
    let bitand_evals = [a_eval, b_eval, c_eval];
    let bitand_poly_eval = evaluate_univariate(&bitand_evals, bitand_lambda);
    let bitand_batched = bitand_lambda * bitand_poly_eval;

    // IntMul: no constraints, batched_eval = 0
    let intmul_batched = B128::ZERO;

    let shift_eval = bitand_batched + intmul_batched;
    println!("  bitand_batched_eval: 0x{:032x}", u128::from(bitand_batched));
    println!("  shift phase1 claim (eval): 0x{:032x}", u128::from(shift_eval));

    // 4c: Phase 1 sumcheck: LOG_WORD_SIZE_BITS * 2 = 12 rounds
    let phase1_vars = LOG_WORD_SIZE_BITS * 2; // = 12
    println!("\n  4c: Phase 1 sumcheck ({} rounds)", phase1_vars);
    let offset_before_phase1 = offset!();
    let mut phase1_sum = shift_eval;
    let mut r_jr_s: Vec<B128> = Vec::new();
    for round in 0..phase1_vars {
        let a: B128 = vt.message().read_scalar().unwrap();
        let b: B128 = vt.message().read_scalar().unwrap();
        let c: B128 = vt.message().read_scalar().unwrap();
        let check = b + c;
        let ok = check == phase1_sum;
        if round < 3 || !ok {
            println!("      Round {}: ok={}", round, ok);
        }
        let alpha: B128 = vt.sample();
        phase1_sum = a + b * alpha + c * (alpha * alpha);
        r_jr_s.push(alpha);
    }
    let gamma = phase1_sum;
    println!("  Phase 1 bytes: {}", offset!() - offset_before_phase1);
    println!("  gamma (phase1 final eval): 0x{:032x}", u128::from(gamma));

    // Split r_jr_s into r_j (first 6) and r_s (last 6)
    // NOTE: Rust code reverses then splits: r_jr_s.reverse(); r_s = r_jr_s.split_off(6); r_j = r_jr_s;
    r_jr_s.reverse();
    let r_s = r_jr_s.split_off(LOG_WORD_SIZE_BITS);
    let r_j = r_jr_s.clone();
    println!("  r_j (first {}): first=0x{:.8x}", r_j.len(), u128::from(r_j[0]));
    println!("  r_s (last {}): first=0x{:.8x}", r_s.len(), u128::from(r_s[0]));

    // 4d: Sample inout_eval_point (inout_n_vars = 7 challenges)
    println!("\n  4d: Sample {} inout eval point challenges", inout_n_vars);
    let inout_eval_point: Vec<B128> = (0..inout_n_vars).map(|_| vt.sample()).collect();
    println!("  inout_eval_point[0]: 0x{:032x}", u128::from(inout_eval_point[0]));

    // 4e: Compute public_eval from public words + r_j + inout_eval_point
    // (complex computation, skip for now)
    println!("\n  4e: public_eval computation (skipping complex formula)");

    // 4f: Sample batch_coeff
    let batch_coeff: B128 = vt.sample();
    println!("  batch_coeff: 0x{:032x}", u128::from(batch_coeff));

    // 4g: Phase 2 sumcheck: log_word_count = 18 rounds
    println!("\n  4g: Phase 2 sumcheck ({} rounds)", log_word_count);
    // NOTE: We don't have the exact public_eval, so we can't verify the sum.
    // We trace the byte consumption only.
    let offset_before_phase2 = offset!();
    let mut r_y: Vec<B128> = Vec::new();
    for round in 0..log_word_count {
        let a: B128 = vt.message().read_scalar().unwrap();
        let b: B128 = vt.message().read_scalar().unwrap();
        let c: B128 = vt.message().read_scalar().unwrap();
        let alpha: B128 = vt.sample();
        let _ = (a, b, c, alpha); // don't verify since we don't have public_eval
        r_y.push(alpha);
        if round < 2 {
            println!("      Round {}: a=0x{:.8x} alpha=0x{:.8x}", round, u128::from(a), u128::from(alpha));
        }
    }
    println!("  Phase 2 bytes: {}", offset!() - offset_before_phase2);

    // 4h: Read witness_eval
    let witness_eval: B128 = vt.message().read_scalar().unwrap();
    println!("  witness_eval: 0x{:032x}", u128::from(witness_eval));

    let after_shift = offset!();
    println!("\n  Shift total bytes: {}", after_shift - before_shift);
    println!("  transcript_offset after Shift: {}", after_shift);

    // ─── Step 5: Ring-switch ──────────────────────────────────────────────────
    println!("\n--- Step 5: Ring-switch ---");
    let before_rs = offset!();

    // Read s_hat_v: 128 GF128 values (message, observe)
    println!("  Reading 128 s_hat_v values from proof");
    let rs_packing_size = 1 << 7; // 128
    let mut s_hat_v: Vec<B128> = Vec::with_capacity(rs_packing_size);
    for _ in 0..rs_packing_size {
        let val: B128 = vt.message().read_scalar().unwrap();
        s_hat_v.push(val);
    }
    println!("  s_hat_v[0]: 0x{:032x}", u128::from(s_hat_v[0]));
    println!("  s_hat_v bytes: {}", offset!() - before_rs);

    // Sample 7 r'' challenges
    let r_double_prime: Vec<B128> = (0..7).map(|_| vt.sample()).collect();
    println!("  r_double_prime[0]: 0x{:032x}", u128::from(r_double_prime[0]));

    let after_rs = offset!();
    println!("  Ring-switch total bytes: {}", after_rs - before_rs);
    println!("  transcript_offset after RingSwitch: {}", after_rs);

    // ─── Step 6: BaseFold/FRI ─────────────────────────────────────────────────
    println!("\n--- Step 6: BaseFold/FRI ---");
    let before_fri = offset!();

    // FRI folding: log_word_count + log_packing = 18 + 7 = 25 rounds?
    // Actually: nVars = log(witness) = 18
    println!("  log_word_count (FRI nVars): {}", log_word_count);

    // Each round: read 3 GF128 (sumcheck round poly, message), read 32-byte commitment (message), sample challenge
    // BUT: not every round has a commitment. The commit_rounds array determines which rounds get commitments.
    // For now, let's trace and see what structure we find.

    // Try to read FRI rounds
    println!("  Attempting to read FRI rounds...");
    let mut fri_offset = offset!();

    // Read first few rounds to understand the structure
    for round in 0..3 {
        let start = offset!();
        // Read sumcheck coefficients (DEGREE+1 = 3 GF128 values? Or DEGREE = 2 elements?)
        // From the code: RoundCoeffs(transcript.message().read_vec(DEGREE)?)) with DEGREE=2
        // So reads 2 GF128 values, not 3!
        let a: B128 = vt.message().read_scalar().unwrap();
        let b: B128 = vt.message().read_scalar().unwrap();

        // Also sample challenge (or is it read after commitment?)
        // From the code: read_vec(DEGREE) = 2 elements, then process_round reads commitment, then sample challenge
        let end_after_round_poly = offset!();

        // Try reading commitment
        let mut commit = [0u8; 32];
        let _ = vt.message().read_bytes(&mut commit);
        let end_after_commit = offset!();

        // Sample challenge
        let alpha: B128 = vt.sample();

        println!("  FRI round {}: round_poly_bytes={} commit_bytes={} alpha=0x{:.8x}",
            round,
            end_after_round_poly - start,
            end_after_commit - end_after_round_poly,
            u128::from(alpha));
        println!("      a=0x{:.8x} b=0x{:.8x} commit={}", u128::from(a), u128::from(b), hex::encode(&commit));
    }

    println!("  transcript_offset after 3 FRI rounds: {}", offset!());
    println!("\n  Full proof bytes: {}", total_proof_bytes);
    println!("  Remaining bytes: {}", vt.remaining_bytes());

    Ok(())
}
