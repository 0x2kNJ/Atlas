// export-transcript-vectors: Generate Fiat-Shamir test vectors for the Solidity transcript.
//
// Usage:
//   cargo run --release --bin export-transcript-vectors

use binius_core::word::Word;
use binius_transcript::VerifierTranscript;
use binius_transcript::fiat_shamir::CanSample;
use binius_verifier::config::StdChallenger;
use binius_field::BinaryField128bGhash as B128;

fn main() {
    println!("=== HasherChallenger<Sha256> Test Vectors ===\n");

    // Test 1: Initial sample — no observation, just sample a GF128 challenge
    {
        let challenger = StdChallenger::default();
        let mut vt = VerifierTranscript::new(challenger, Vec::new());
        let s: B128 = vt.sample();
        println!("Test 1: Initial sample (GF128, no observation)");
        println!("  result_u128: 0x{:032x}", u128::from(s));
        println!();
    }

    // Test 2: Observe 8 bytes, then sample
    {
        let challenger = StdChallenger::default();
        let mut vt = VerifierTranscript::new(challenger, Vec::new());
        vt.observe().write_slice(&[0xDEu8, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE]);
        let s: B128 = vt.sample();
        println!("Test 2: Observe [DEADBEEFCAFEBABE] then sample GF128");
        println!("  result_u128: 0x{:032x}", u128::from(s));
        println!();
    }

    // Test 3: Read GF128 from proof tape via message(), then sample
    {
        let challenger = StdChallenger::default();
        let proof: Vec<u8> = vec![
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
        ];
        let mut vt = VerifierTranscript::new(challenger, proof);
        let msg: B128 = vt.message().read_scalar().unwrap();
        let s: B128 = vt.sample();
        println!("Test 3: Read GF128 from proof tape via message(), then sample");
        println!("  msg_u128: 0x{:032x}", u128::from(msg));
        println!("  sample_u128: 0x{:032x}", u128::from(s));
        println!();
    }

    // Test 4: Observe public inputs (u64 words), read commitment (32 bytes), then sample
    {
        let challenger = StdChallenger::default();
        let mut proof = Vec::new();
        proof.extend_from_slice(&[0xAA; 32]); // commitment
        let mut vt = VerifierTranscript::new(challenger, proof);

        // Observe public inputs as u64 LE (like the real verifier)
        let public_words = [Word(100_000_000u64), Word(75_000_000u64)];
        vt.observe().write_slice(&public_words);

        // Read commitment
        let mut commitment = [0u8; 32];
        vt.message().read_bytes(&mut commitment);

        let s: B128 = vt.sample();
        println!("Test 4: Observe public inputs, read 32-byte commitment, sample GF128");
        println!("  commitment: {}", hex::encode(&commitment));
        println!("  sample_u128: 0x{:032x}", u128::from(s));
        println!();
    }

    // Test 5: Multiple observe-sample cycles
    {
        let challenger = StdChallenger::default();
        let mut vt = VerifierTranscript::new(challenger, Vec::new());

        vt.observe().write_bytes(&[0x11u8; 8]);
        let s1: B128 = vt.sample();

        vt.observe().write_bytes(&[0x22u8; 8]);
        let s2: B128 = vt.sample();

        println!("Test 5: Multiple observe-sample cycles");
        println!("  observe [1111111111111111], sample1: 0x{:032x}", u128::from(s1));
        println!("  observe [2222222222222222], sample2: 0x{:032x}", u128::from(s2));
        println!();
    }

    // Test 6: Sample twice consecutively (no observation between)
    {
        let challenger = StdChallenger::default();
        let mut vt = VerifierTranscript::new(challenger, Vec::new());

        vt.observe().write_bytes(&[0xFFu8; 4]);
        let s1: B128 = vt.sample();
        let s2: B128 = vt.sample();

        println!("Test 6: Sample twice without intermediate observation");
        println!("  observe [FFFFFFFF], sample1: 0x{:032x}", u128::from(s1));
        println!("  sample2: 0x{:032x}", u128::from(s2));
    }
}
