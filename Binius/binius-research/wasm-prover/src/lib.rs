// binius-wasm-prover
//
// Browser-side Binius64 prover for the Envelope Protocol.
// Exports three wasm-bindgen functions:
//
//   prove_encumber(input: JsValue) -> Result<JsValue, JsValue>
//   prove_spend(input: JsValue)    -> Result<JsValue, JsValue>
//   prove_settle(input: JsValue)   -> Result<JsValue, JsValue>
//
// All three take a JSON object with circuit-specific fields and return:
//   {
//     proof_hex:     "0x<hex>",           // raw proof bytes
//     proof_size_kb: <number>,
//     public_inputs: ["<hex64>", ...],    // public words as 16-char LE hex strings
//   }
//
// No rayon is used — binius-utils falls back to sequential iterators when the
// "rayon" feature is absent, which is the only change needed for WASM.

use wasm_bindgen::prelude::*;
use serde::{Deserialize, Serialize};

use anyhow::Result;
use binius_frontend::CircuitBuilder;
use binius_hash::{ParallelCompressionAdaptor, StdCompression, StdDigest};
use binius_prover::{OptimalPackedB128, Prover};
use binius_transcript::{ProverTranscript, VerifierTranscript};
use binius_verifier::{Verifier, config::StdChallenger};

use envelope_circuits::{
    encumber::EncumberCircuit,
    spend::SpendCircuit,
    settle::SettleCircuit,
};

// ── Type aliases (mirrors binius-examples without pulling in ureq/ethsign) ───

type StdVerifier = Verifier<StdDigest, StdCompression>;
type StdProver = Prover<OptimalPackedB128, ParallelCompressionAdaptor<StdCompression>, StdDigest>;

fn setup_sha256(
    cs: binius_core::constraint_system::ConstraintSystem,
    log_inv_rate: usize,
) -> Result<(StdVerifier, StdProver)> {
    let parallel_compression = ParallelCompressionAdaptor::new(StdCompression::default());
    let compression = parallel_compression.compression().clone();
    let verifier = Verifier::setup(cs, log_inv_rate, compression)?;
    let prover = Prover::setup(verifier.clone(), parallel_compression)?;
    Ok((verifier, prover))
}

// ── Shared proof output ───────────────────────────────────────────────────────

#[derive(Serialize)]
struct ProofOutput {
    proof_hex: String,
    proof_size_kb: f64,
    /// Public witness words as 16-char little-endian hex strings, one per u64 word.
    public_inputs: Vec<String>,
}

fn prove_and_serialize(
    verifier: &StdVerifier,
    prover: &StdProver,
    witness: binius_core::constraint_system::ValueVec,
) -> Result<ProofOutput> {
    let public_words: Vec<u64> = witness.public().iter().map(|w| w.0).collect();

    let challenger = StdChallenger::default();
    let mut pt = ProverTranscript::new(challenger);
    prover.prove(witness, &mut pt)?;
    let proof_bytes = pt.finalize();

    // Verify immediately so a browser gets a hard error on invalid witness
    let challenger = StdChallenger::default();
    let mut vt = VerifierTranscript::new(challenger, proof_bytes.clone());
    verifier.verify(
        &public_words
            .iter()
            .map(|&w| binius_core::word::Word(w))
            .collect::<Vec<_>>(),
        &mut vt,
    )?;
    vt.finalize()?;

    Ok(ProofOutput {
        proof_hex: format!("0x{}", hex::encode(&proof_bytes)),
        proof_size_kb: proof_bytes.len() as f64 / 1024.0,
        public_inputs: public_words
            .iter()
            .map(|w| format!("{:016x}", w))
            .collect(),
    })
}

// ── Encumber ──────────────────────────────────────────────────────────────────

/// JS input for prove_encumber.
/// All byte arrays are passed as 0x-prefixed hex strings.
#[derive(Deserialize)]
struct EncumberInput {
    /// u64 note value (sat / wei / micro-unit depending on asset)
    note_value: u64,
    /// 32-byte note randomness, 0x-prefixed hex
    note_rand: String,
    /// 32-byte owner public key, 0x-prefixed hex
    owner_pk: String,
    /// u64 collateral amount — circuit enforces note_value >= collateral_amount
    collateral_amount: u64,
    /// log2(inverse code rate) for FRI, default 1 (rate=1/2, ~265 KB proof)
    #[serde(default = "default_log_inv_rate")]
    log_inv_rate: usize,
}

fn default_log_inv_rate() -> usize { 1 }

/// Generate a Binius64 Encumber proof in the browser.
///
/// ```js
/// const result = await prove_encumber({
///   note_value:        100_000_000n,
///   note_rand:         "0x" + "42".repeat(32),
///   owner_pk:          "0x" + "11".repeat(32),
///   collateral_amount: 75_000_000n,
/// });
/// console.log(result.proof_hex, result.proof_size_kb);
/// ```
#[wasm_bindgen]
pub fn prove_encumber(input: JsValue) -> Result<JsValue, JsValue> {
    let inp: EncumberInput = serde_wasm_bindgen::from_value(input)
        .map_err(|e| JsValue::from_str(&format!("input parse error: {e}")))?;

    let note_rand = parse_hex32(&inp.note_rand)
        .map_err(|e| JsValue::from_str(&format!("note_rand: {e}")))?;
    let owner_pk = parse_hex32(&inp.owner_pk)
        .map_err(|e| JsValue::from_str(&format!("owner_pk: {e}")))?;

    run_encumber(inp.note_value, note_rand, owner_pk, inp.collateral_amount, inp.log_inv_rate)
        .map(|out| serde_wasm_bindgen::to_value(&out).unwrap())
        .map_err(|e| JsValue::from_str(&format!("prove_encumber failed: {e:#}")))
}

fn run_encumber(
    note_value: u64,
    note_rand: [u8; 32],
    owner_pk: [u8; 32],
    collateral_amount: u64,
    log_inv_rate: usize,
) -> Result<ProofOutput> {
    let mut builder = CircuitBuilder::new();
    let circuit = EncumberCircuit::build(&mut builder);
    let built = builder.build();
    let cs = built.constraint_system().clone();

    let (verifier, prover) = setup_sha256(cs, log_inv_rate)?;

    let mut filler = built.new_witness_filler();
    circuit.populate(&mut filler, note_value, note_rand, owner_pk, collateral_amount);
    built.populate_wire_witness(&mut filler)?;
    let witness = filler.into_value_vec();

    prove_and_serialize(&verifier, &prover, witness)
}

// ── Spend ─────────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct SpendInput {
    in_value:  u64,
    in_rand:   String,
    in_pk:     String,
    out_value: u64,
    out_rand:  String,
    out_pk:    String,
    #[serde(default = "default_log_inv_rate")]
    log_inv_rate: usize,
}

/// Generate a Binius64 Spend proof in the browser.
///
/// ```js
/// const result = await prove_spend({
///   in_value:  100_000_000n,
///   in_rand:   "0x" + "42".repeat(32),
///   in_pk:     "0x" + "11".repeat(32),
///   out_value:  95_000_000n,
///   out_rand:  "0x" + "ab".repeat(32),
///   out_pk:    "0x" + "cd".repeat(32),
/// });
/// ```
#[wasm_bindgen]
pub fn prove_spend(input: JsValue) -> Result<JsValue, JsValue> {
    let inp: SpendInput = serde_wasm_bindgen::from_value(input)
        .map_err(|e| JsValue::from_str(&format!("input parse error: {e}")))?;

    let in_rand  = parse_hex32(&inp.in_rand) .map_err(|e| JsValue::from_str(&format!("in_rand: {e}")))?;
    let in_pk    = parse_hex32(&inp.in_pk)   .map_err(|e| JsValue::from_str(&format!("in_pk: {e}")))?;
    let out_rand = parse_hex32(&inp.out_rand).map_err(|e| JsValue::from_str(&format!("out_rand: {e}")))?;
    let out_pk   = parse_hex32(&inp.out_pk)  .map_err(|e| JsValue::from_str(&format!("out_pk: {e}")))?;

    run_spend(inp.in_value, in_rand, in_pk, inp.out_value, out_rand, out_pk, inp.log_inv_rate)
        .map(|out| serde_wasm_bindgen::to_value(&out).unwrap())
        .map_err(|e| JsValue::from_str(&format!("prove_spend failed: {e:#}")))
}

fn run_spend(
    in_value: u64, in_rand: [u8; 32], in_pk: [u8; 32],
    out_value: u64, out_rand: [u8; 32], out_pk: [u8; 32],
    log_inv_rate: usize,
) -> Result<ProofOutput> {
    let mut builder = CircuitBuilder::new();
    let circuit = SpendCircuit::build(&mut builder);
    let built = builder.build();
    let cs = built.constraint_system().clone();

    let (verifier, prover) = setup_sha256(cs, log_inv_rate)?;

    let mut filler = built.new_witness_filler();
    circuit.populate(&mut filler, in_value, in_rand, in_pk, out_value, out_rand, out_pk);
    built.populate_wire_witness(&mut filler)?;
    let witness = filler.into_value_vec();

    prove_and_serialize(&verifier, &prover, witness)
}

// ── Settle ────────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct SettleInput {
    in_value:  u64,
    in_rand:   String,
    in_pk:     String,
    out_value: u64,
    out_rand:  String,
    out_pk:    String,
    #[serde(default = "default_log_inv_rate")]
    log_inv_rate: usize,
}

/// Generate a Binius64 Settle proof in the browser.
#[wasm_bindgen]
pub fn prove_settle(input: JsValue) -> Result<JsValue, JsValue> {
    let inp: SettleInput = serde_wasm_bindgen::from_value(input)
        .map_err(|e| JsValue::from_str(&format!("input parse error: {e}")))?;

    let in_rand  = parse_hex32(&inp.in_rand) .map_err(|e| JsValue::from_str(&format!("in_rand: {e}")))?;
    let in_pk    = parse_hex32(&inp.in_pk)   .map_err(|e| JsValue::from_str(&format!("in_pk: {e}")))?;
    let out_rand = parse_hex32(&inp.out_rand).map_err(|e| JsValue::from_str(&format!("out_rand: {e}")))?;
    let out_pk   = parse_hex32(&inp.out_pk)  .map_err(|e| JsValue::from_str(&format!("out_pk: {e}")))?;

    run_settle(inp.in_value, in_rand, in_pk, inp.out_value, out_rand, out_pk, inp.log_inv_rate)
        .map(|out| serde_wasm_bindgen::to_value(&out).unwrap())
        .map_err(|e| JsValue::from_str(&format!("prove_settle failed: {e:#}")))
}

fn run_settle(
    in_value: u64, in_rand: [u8; 32], in_pk: [u8; 32],
    out_value: u64, out_rand: [u8; 32], out_pk: [u8; 32],
    log_inv_rate: usize,
) -> Result<ProofOutput> {
    let mut builder = CircuitBuilder::new();
    let circuit = SettleCircuit::build(&mut builder);
    let built = builder.build();
    let cs = built.constraint_system().clone();

    let (verifier, prover) = setup_sha256(cs, log_inv_rate)?;

    let mut filler = built.new_witness_filler();
    circuit.populate(&mut filler, in_value, in_rand, in_pk, out_value, out_rand, out_pk);
    built.populate_wire_witness(&mut filler)?;
    let witness = filler.into_value_vec();

    prove_and_serialize(&verifier, &prover, witness)
}

// ── Utility ───────────────────────────────────────────────────────────────────

/// Decode a 0x-prefixed hex string into a 32-byte array.
fn parse_hex32(s: &str) -> Result<[u8; 32], String> {
    let s = s.strip_prefix("0x").unwrap_or(s);
    let bytes = hex::decode(s).map_err(|e| e.to_string())?;
    bytes
        .try_into()
        .map_err(|_| format!("expected 32 bytes, got {}", s.len() / 2))
}

/// Expose package version to JS for diagnostics.
#[wasm_bindgen]
pub fn prover_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

// ── WASM tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use wasm_bindgen_test::*;
    wasm_bindgen_test_configure!(run_in_browser);

    use super::*;

    #[wasm_bindgen_test]
    fn test_encumber_round_trip() {
        let result = run_encumber(
            100_000_000,
            [0x42u8; 32],
            [0x11u8; 32],
            75_000_000,
            1,
        );
        assert!(result.is_ok(), "encumber proof failed: {:?}", result.err());
        let out = result.unwrap();
        assert!(out.proof_hex.starts_with("0x"));
        assert!(out.proof_size_kb > 100.0, "proof too small — may be mocked");
    }

    #[wasm_bindgen_test]
    fn test_spend_round_trip() {
        let result = run_spend(
            100_000_000, [0x42u8; 32], [0x11u8; 32],
             95_000_000, [0xabu8; 32], [0xcdu8; 32],
            1,
        );
        assert!(result.is_ok(), "spend proof failed: {:?}", result.err());
    }

    #[wasm_bindgen_test]
    fn test_settle_round_trip() {
        let result = run_settle(
            100_000_000, [0x42u8; 32], [0x11u8; 32],
             95_000_000, [0xabu8; 32], [0xcdu8; 32],
            1,
        );
        assert!(result.is_ok(), "settle proof failed: {:?}", result.err());
    }
}
