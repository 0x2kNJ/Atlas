/// Compute and export NTT twiddle basis elements for the binius64 FRI fold verification.
///
/// For the binius64 Encumber circuit with:
///   - log_batch_size = 4, log_dim = 14, log_inv_rate = 1
///   - RS code subspace dimension = 15
///   - NTT log_domain_size = 15
///
/// The FRI fold verification needs twiddle factors for layers 6..14.
/// Each layer's twiddle(layer, block) = XOR of twiddle_basis[i] for set bits in block.

use binius_field::{BinaryField128bGhash, Field};
use binius_math::BinarySubspace;
use binius_math::ntt::DomainContext;
use binius_math::ntt::domain_context::GenericOnTheFly;
use binius_math::line::extrapolate_line;

fn fold_pair(
    dc: &GenericOnTheFly<BinaryField128bGhash>,
    round: usize,
    index: usize,
    u_in: BinaryField128bGhash,
    v_in: BinaryField128bGhash,
    r: BinaryField128bGhash,
) -> BinaryField128bGhash {
    let t = dc.twiddle(round - 1, index);
    let mut u = u_in;
    let mut v = v_in;
    v += u;
    u += v * t;
    extrapolate_line(u, v, r)
}

fn fold_pair_traced(
    dc: &GenericOnTheFly<BinaryField128bGhash>,
    round: usize,
    index: usize,
    u_in: BinaryField128bGhash,
    v_in: BinaryField128bGhash,
    r: BinaryField128bGhash,
) -> BinaryField128bGhash {
    let t = dc.twiddle(round - 1, index);
    eprintln!("  fold_pair(round={}, idx={}) twiddle({},{})=0x{:032x}",
        round, index, round-1, index, u128::from(t));
    eprintln!("    u_in=0x{:032x} v_in=0x{:032x} r=0x{:032x}",
        u128::from(u_in), u128::from(v_in), u128::from(r));
    let mut u = u_in;
    let mut v = v_in;
    v += u;
    u += v * t;
    let result = extrapolate_line(u, v, r);
    eprintln!("    v'=0x{:032x} u'=0x{:032x} result=0x{:032x}",
        u128::from(v), u128::from(u), u128::from(result));
    result
}

fn fold_chunk_traced(
    dc: &GenericOnTheFly<BinaryField128bGhash>,
    mut log_len: usize,
    chunk_index: usize,
    values: &mut [BinaryField128bGhash],
    challenges: &[BinaryField128bGhash],
) -> BinaryField128bGhash {
    let mut log_size = challenges.len();
    for (k, &challenge) in challenges.iter().enumerate() {
        eprintln!("--- Round k={} logLen={} logSize={} challenge=0x{:032x} ---",
            k, log_len, log_size, u128::from(challenge));
        for index_offset in 0..1usize << (log_size - 1) {
            let pair = (values[index_offset << 1], values[(index_offset << 1) | 1]);
            values[index_offset] = fold_pair_traced(
                dc,
                log_len,
                (chunk_index << (log_size - 1)) | index_offset,
                pair.0,
                pair.1,
                challenge,
            );
        }
        log_len -= 1;
        log_size -= 1;
    }
    values[0]
}

fn fold_chunk(
    dc: &GenericOnTheFly<BinaryField128bGhash>,
    mut log_len: usize,
    chunk_index: usize,
    values: &mut [BinaryField128bGhash],
    challenges: &[BinaryField128bGhash],
) -> BinaryField128bGhash {
    let mut log_size = challenges.len();
    for &challenge in challenges {
        for index_offset in 0..1 << (log_size - 1) {
            let pair = (values[index_offset << 1], values[(index_offset << 1) | 1]);
            values[index_offset] = fold_pair(
                dc,
                log_len,
                (chunk_index << (log_size - 1)) | index_offset,
                pair.0,
                pair.1,
                challenge,
            );
        }
        log_len -= 1;
        log_size -= 1;
    }
    values[0]
}

fn test_field_mul() {
    // Test basic field multiplications to understand the convention
    let a = BinaryField128bGhash::new(0x201);
    let b = BinaryField128bGhash::new(0x201);
    println!("// 0x201 * 0x201 = 0x{:032x}", u128::from(a * b));

    let c = BinaryField128bGhash::new(0x203);
    let d = BinaryField128bGhash::new(0x203);
    println!("// 0x203 * 0x203 = 0x{:032x}", u128::from(c * d));

    let e = BinaryField128bGhash::new(2);
    let f = BinaryField128bGhash::new(2);
    println!("// 2 * 2 = 0x{:032x}", u128::from(e * f));

    let g = BinaryField128bGhash::new(2);
    let h = BinaryField128bGhash::new(3);
    println!("// 2 * 3 = 0x{:032x}", u128::from(g * h));

    let i = BinaryField128bGhash::new(0x40001);
    let j = BinaryField128bGhash::new(0x40005);
    println!("// 0x40001 * 0x40005 = 0x{:032x}", u128::from(i * j));

    // Check mul_by_x
    // mul_primitive not implemented for BinaryField128bGhash
    let two = BinaryField128bGhash::new(2);
    let three = BinaryField128bGhash::new(3);
    let four = BinaryField128bGhash::new(4);
    println!("// 2 * 2 = 0x{:032x}", u128::from(two * two));
    println!("// 3 * 3 = 0x{:032x}", u128::from(three * three));
    println!("// 4 * 4 = 0x{:032x}", u128::from(four * four));

    // Test the squaring of our specific values
    println!();
    println!("// eq_ind tensor intermediate values:");
    let r0 = BinaryField128bGhash::new(0x200);
    let r1 = BinaryField128bGhash::new(0x201);
    let r2 = BinaryField128bGhash::new(0x202);
    let r3 = BinaryField128bGhash::new(0x203);
    let one = BinaryField128bGhash::ONE;
    println!("// 1+r0 = 0x{:032x}", u128::from(one + r0));
    println!("// 1+r1 = 0x{:032x}", u128::from(one + r1));
    println!("// 1+r2 = 0x{:032x}", u128::from(one + r2));
    println!("// 1+r3 = 0x{:032x}", u128::from(one + r3));
    // tensor[5] = (1+r0) * r1 * (1+r2) * r3
    let t5 = (one + r0) * r1 * (one + r2) * r3;
    println!("// tensor[5] = (1+r0)*r1*(1+r2)*r3 = 0x{:032x}", u128::from(t5));
    // Also check step by step
    let step1 = (one + r0) * r1;
    println!("// (1+r0)*r1 = 0x{:032x}", u128::from(step1));
    let step2 = (one + r2) * r3;
    println!("// (1+r2)*r3 = 0x{:032x}", u128::from(step2));
    let step3 = step1 * step2;
    println!("// step1*step2 = 0x{:032x}", u128::from(step3));
}

fn main() {
    test_field_mul();

    // The verifier's NTT setup is two-level:
    // 1. Create initial NTT from canonical BinarySubspace::with_dim(log_code_len)
    //    where log_code_len = log_witness_elems + log_inv_rate = 17 + 1 = 18
    // 2. Get the RS code subspace: ntt.domain_context().subspace(log_dim + log_inv_rate)
    //    where log_dim = 13, log_inv_rate = 1, so subspace(14)
    // 3. Create a SECOND NTT from the RS code subspace for fold_chunk
    let initial_log_domain_size: usize = 18;
    let rs_code_subspace_dim: usize = 14;

    let canonical_subspace = BinarySubspace::<BinaryField128bGhash>::with_dim(initial_log_domain_size);
    eprintln!("Step 1: Canonical subspace dim={}", canonical_subspace.dim());

    let dc1 = GenericOnTheFly::generate_from_subspace(&canonical_subspace);
    eprintln!("dc1.log_domain_size() = {}", dc1.log_domain_size());

    // Step 2: Get the RS code subspace
    let rs_code_subspace = dc1.subspace(rs_code_subspace_dim);
    eprintln!("\nStep 2: RS code subspace (dc1.subspace({})) basis:", rs_code_subspace_dim);
    for (i, b) in rs_code_subspace.basis().iter().enumerate() {
        eprintln!("  rs_beta_{} = 0x{:032x}", i, u128::from(*b));
    }

    // Step 3: Create the second NTT used by the verifier's fold_chunk
    let dc = GenericOnTheFly::generate_from_subspace(&rs_code_subspace);
    eprintln!("\nStep 3: dc2 (from RS code subspace) for twiddle generation");
    eprintln!("dc2.log_domain_size() = {}", dc.log_domain_size());
    let log_domain_size = dc.log_domain_size();

    eprintln!("\nlog_domain_size = {}", dc.log_domain_size());

    println!("// NTT twiddle basis elements for binius64 FRI fold verification");
    println!("// log_domain_size = {}", log_domain_size);
    println!("// Field: BinaryField128bGhash (x^128 + x^7 + x^2 + x + 1)");
    println!("// Subspace: canonical (basis(i) = 1 << i)");
    println!();

    for layer in (6..=13).rev() {
        let n_basis = layer;

        println!("// Layer {} twiddle subspace ({} basis elements):", layer, n_basis);

        for b in 0..n_basis {
            let block = 1usize << b;
            let tw = dc.twiddle(layer, block);
            let val = u128::from(tw);
            println!("// TWIDDLE_BASIS[layer={}][{}] = 0x{:032x}", layer, b, val);
        }

        // Verify twiddle(layer, 0) == 0
        let tw0 = dc.twiddle(layer, 0);
        assert_eq!(u128::from(tw0), 0, "twiddle(layer={}, 0) should be 0", layer);

        // Verify XOR property
        if n_basis >= 2 {
            let tw3 = dc.twiddle(layer, 3);
            let tw1 = dc.twiddle(layer, 1);
            let tw2 = dc.twiddle(layer, 2);
            let expected = u128::from(tw1) ^ u128::from(tw2);
            assert_eq!(u128::from(tw3), expected, "twiddle XOR check failed for layer {}", layer);
        }

        println!();
    }

    // Solidity-ready format
    println!("// =====================================================");
    println!("// Solidity-ready twiddle basis arrays (hex, LE u128)");
    println!("// =====================================================");
    println!();

    for layer in (6..=13).rev() {
        let n_basis = layer;
        println!("// Layer {} ({} basis elements)", layer, n_basis);
        for b in 0..n_basis {
            let block = 1usize << b;
            let tw = dc.twiddle(layer, block);
            let val = u128::from(tw);
            println!("uint256 constant TWIDDLE_L{}_B{} = 0x{:032x};", layer, b, val);
        }
        println!();
    }

    // Fold test vectors
    println!("// =====================================================");
    println!("// Fold test vectors (fold_chunk)");
    println!("// =====================================================");
    println!();

    // Test fold_chunk with simple values
    let mut test_values: Vec<BinaryField128bGhash> = (0..16)
        .map(|i| BinaryField128bGhash::new(i + 1))
        .collect();
    let test_challenges: Vec<BinaryField128bGhash> = (0..4)
        .map(|i| BinaryField128bGhash::new(0x100 + i))
        .collect();

    println!("// fold_chunk(log_len=14, chunk_index=0, values=[1..16], challenges=[0x100..0x103])");
    let result = fold_chunk(&dc, 14, 0, &mut test_values, &test_challenges);
    println!("// Result: 0x{:032x}", u128::from(result));

    // Test with chunk_index = 1
    let mut test_values2: Vec<BinaryField128bGhash> = (0..16)
        .map(|i| BinaryField128bGhash::new(i + 1))
        .collect();
    let result2 = fold_chunk(&dc, 14, 1, &mut test_values2, &test_challenges);
    println!("// Result (chunk_index=1): 0x{:032x}", u128::from(result2));

    // Interleave tensor test
    println!();
    println!("// =====================================================");
    println!("// Interleave fold (eq_ind tensor)");
    println!("// =====================================================");

    use binius_math::multilinear::eq::eq_ind_partial_eval;

    let interleave_challenges: Vec<BinaryField128bGhash> = (0..4)
        .map(|i| BinaryField128bGhash::new(0x200 + i))
        .collect();

    let tensor = eq_ind_partial_eval(&interleave_challenges);
    let tensor_slice: &[BinaryField128bGhash] = tensor.as_ref();
    println!("// eq_ind_partial_eval([0x200, 0x201, 0x202, 0x203]):");
    for (i, t) in tensor_slice.iter().enumerate() {
        println!("//   tensor[{:2}] = 0x{:032x}", i, u128::from(*t));
    }

    // Verify fold_interleaved_chunk = inner_product(values, tensor)
    println!();
    let test_coset: Vec<BinaryField128bGhash> = (0..16)
        .map(|i| BinaryField128bGhash::new(i + 1))
        .collect();
    let mut interleave_result = BinaryField128bGhash::ZERO;
    for (v, t) in test_coset.iter().zip(tensor_slice.iter()) {
        interleave_result += *v * *t;
    }
    println!("// fold_interleaved_chunk(values=[1..16], tensor_from([0x200..0x203]))");
    println!("// Result: 0x{:032x}", u128::from(interleave_result));

    // Real-world E2E test: fold_chunk with exact values from query 11845
    eprintln!("\n=== REAL WORLD fold_chunk trace (query 11845, oracle1->oracle2) ===");
    let real_v: Vec<u128> = vec![
        0xc700aa23415f9f44578d9385de83e12f,
        0xdfef35c3de7baa46803d42fe073d8fb3,
        0x27128e61c305e188f10276beda86db19,
        0xbbe89fc3df57c07574a9598d894258d9,
        0x25422d5ea73c1a0b19c669493f670511,
        0xf2f33f468c0d5099b982c34528138fff,
        0x80dc3ad81be1b86b0e6e821478ee5fef,
        0xc3c0b9497c1ff4b423ce5aec8bbd9fa2,
        0x7032e6ead67500be44a139969c049f2e,
        0x54d75235ea595350479cdbe42d934163,
        0x436063c156b1185942ee6097c96fce05,
        0xd44d26739910faa65ab002a62199e288,
        0xf10fc3389f0cbbae47cd977c036f6517,
        0x3041e063801197ac89f0017006bb652f,
        0x2e74119dbd987c4f96b64a481e1d7e9c,
        0x20343a1fa40fe716b24faeb87449ed0e,
    ];
    let real_ch: Vec<u128> = vec![
        0x600222bcc288b82968126f0ab74c057c,
        0x367ad45c7f7edcf61f11d7310fefe342,
        0x4b3d962f6a6bf00cfc7f34bf03bc7902,
        0xc7112abf5f40da669c86207a853aee23,
    ];
    let mut values_gf: Vec<BinaryField128bGhash> = real_v.iter()
        .map(|&x| BinaryField128bGhash::new(x))
        .collect();
    let challenges_gf: Vec<BinaryField128bGhash> = real_ch.iter()
        .map(|&x| BinaryField128bGhash::new(x))
        .collect();
    let real_result = fold_chunk_traced(&dc, 14, 740, &mut values_gf, &challenges_gf);
    eprintln!("=== RESULT: 0x{:032x} ===", u128::from(real_result));
    eprintln!("=== EXPECTED: 0xcd112202c09c2e4814ad5baf74a5b56e ===");
}
