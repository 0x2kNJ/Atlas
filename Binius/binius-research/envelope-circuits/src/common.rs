// Shared helpers for envelope circuits.
//
// Wire format convention (consistent with binius_circuits):
//   All *external* hash/value wires are in LITTLE-ENDIAN format:
//     wire = u64::from_le_bytes(bytes[i*8..(i+1)*8])
//   SHA256 internal wires use a different (XOR'd) format — handled by the gadgets.
//   Use `pack_bytes_into_wires_le` to populate external hash wires.
//
// Hash primitive:
//   We use DoubleSha256 (SHA256∘SHA256) from binius_circuits::bitcoin.
//   This is 1.5× more rounds than single-SHA256 (3 compression rounds vs 2 per 64-byte input).
//   Production circuits would use single-SHA256 or Poseidon2; the timing ratio is documented.

pub use binius_circuits::bitcoin::merkle_path::{MerklePath, SiblingSide};
use binius_frontend::{CircuitBuilder, Wire, WitnessFiller, util::pack_bytes_into_wires_le};
use sha2::{Digest as _, Sha256 as RealSha256};

// ─── Constants ───────────────────────────────────────────────────────────────

/// Merkle tree depth — matches SingletonVault (capacity 2^20 notes).
pub const MERKLE_DEPTH: usize = 20;

/// Domain separator for encumber nullifier (ASCII "nf_encumber" zero-padded to 32 bytes).
pub const DOMAIN_ENCUMBER: [u8; 32] = {
    let mut b = [0u8; 32];
    b[0] = b'n'; b[1] = b'f'; b[2] = b'_'; b[3] = b'e'; b[4] = b'n'; b[5] = b'c';
    b[6] = b'u'; b[7] = b'm'; b[8] = b'b'; b[9] = b'e'; b[10] = b'r';
    b
};

/// Domain separator for spend nullifier.
pub const DOMAIN_SPEND: [u8; 32] = {
    let mut b = [0u8; 32];
    b[0] = b'n'; b[1] = b'f'; b[2] = b'_'; b[3] = b's'; b[4] = b'p';
    b[5] = b'e'; b[6] = b'n'; b[7] = b'd';
    b
};

/// Domain separator for settle nullifier.
pub const DOMAIN_SETTLE: [u8; 32] = {
    let mut b = [0u8; 32];
    b[0] = b'n'; b[1] = b'f'; b[2] = b'_'; b[3] = b's'; b[4] = b'e';
    b[5] = b't'; b[6] = b't'; b[7] = b'l'; b[8] = b'e';
    b
};

// ─── Circuit wire helpers ─────────────────────────────────────────────────────

/// Create four private witness wires representing a 32-byte hash (LE format).
pub fn add_witness_hash(builder: &CircuitBuilder) -> [Wire; 4] {
    std::array::from_fn(|_| builder.add_witness())
}

/// Create four public I/O wires representing a 32-byte hash (LE format).
pub fn add_public_hash(builder: &CircuitBuilder) -> [Wire; 4] {
    std::array::from_fn(|_| builder.add_inout())
}

/// Assert note_value >= threshold using a 64-bit unsigned comparison.
pub fn assert_gte(builder: &CircuitBuilder, note_value: Wire, threshold: Wire) {
    let too_small = builder.icmp_ult(note_value, threshold);
    builder.assert_false("note_value >= threshold", too_small);
}

// ─── Witness population helpers ───────────────────────────────────────────────

/// Fill a [Wire; 4] hash slot with LE-packed bytes (matches MerklePath format).
pub fn fill_hash_le(filler: &mut WitnessFiller, wires: [Wire; 4], bytes: &[u8; 32]) {
    pack_bytes_into_wires_le(filler, &wires, bytes);
}

/// SHA256 of arbitrary bytes.
pub fn sha256_ref(data: &[u8]) -> [u8; 32] {
    RealSha256::digest(data).into()
}

/// SHA256(SHA256(data)) — matches DoubleSha256 circuit.
pub fn double_sha256_ref(data: &[u8]) -> [u8; 32] {
    sha256_ref(&sha256_ref(data))
}

/// SHA256(SHA256(a || b)).
pub fn double_sha256_cat(a: &[u8; 32], b: &[u8; 32]) -> [u8; 32] {
    let mut msg = [0u8; 64];
    msg[..32].copy_from_slice(a);
    msg[32..].copy_from_slice(b);
    double_sha256_ref(&msg)
}

/// Note commitment: DoubleSha256(note_value_le8 || note_rand || owner_pk)
pub fn note_commitment(note_value: u64, note_rand: &[u8; 32], owner_pk: &[u8; 32]) -> [u8; 32] {
    let mut msg = Vec::with_capacity(72);
    msg.extend_from_slice(&note_value.to_le_bytes());
    msg.extend_from_slice(note_rand);
    msg.extend_from_slice(owner_pk);
    double_sha256_ref(&msg)
}

/// Nullifier: DoubleSha256(note_rand || domain_separator)
pub fn nullifier(note_rand: &[u8; 32], domain: &[u8; 32]) -> [u8; 32] {
    let mut msg = [0u8; 64];
    msg[..32].copy_from_slice(note_rand);
    msg[32..].copy_from_slice(domain);
    double_sha256_ref(&msg)
}

/// Build a depth-`depth` Merkle tree from `leaf`, all siblings = [0;32], leaf is always left.
/// Returns (root, siblings_and_sides).
pub fn build_test_merkle_path(
    leaf: [u8; 32],
    depth: usize,
) -> ([u8; 32], Vec<([u8; 32], SiblingSide)>) {
    let mut current = leaf;
    let mut path = Vec::with_capacity(depth);
    for _ in 0..depth {
        let sibling = [0u8; 32];
        // current is the LEFT child, sibling is on the RIGHT
        current = double_sha256_cat(&current, &sibling);
        path.push((sibling, SiblingSide::Right));
    }
    (current, path)
}
