// Atlas Protocol — Compliance Circuit (Binius m3 API)
//
// This circuit is the Binius equivalent of Noir Circuit 1
// (circuits/circuit1/src/main.nr).
//
// WHAT IT PROVES:
//   The prover knows N execution receipts under a capability such that
//   chained SHA-256 compressions reproduce a committed rolling root.
//
// ARCHITECTURE:
//   The m3 SHA-256 gadget operates on 512-bit (16 × u32) message blocks.
//   Each rolling-root step hashes a 160-byte message:
//     prev_root(32) ‖ index(32) ‖ receipt_hash(32) ‖ nullifier(32) ‖ adapter(32)
//
//   160 bytes requires 3 SHA-256 compression rounds (with padding):
//     Block 0: bytes  0–63   (first 64 bytes of message)
//     Block 1: bytes 64–127  (next 64 bytes)
//     Block 2: bytes 128–159 + padding (last 32 bytes + length)
//
//   For N=64 receipts: 3 × 64 = 192 SHA-256 compression calls.
//
// The m3 SHA-256 gadget treats each table row as one compression call
// on a 512-bit block. We feed it pre-formatted blocks.

use sha2::{Digest, Sha256};

/// Maximum number of receipt slots (matches Noir Circuit 1 MAX_N).
pub const MAX_N: usize = 64;

/// SHA-256 blocks per rolling root step (3 for 160-byte message with padding).
pub const BLOCKS_PER_STEP: usize = 3;

/// Total SHA-256 compressions for MAX_N receipts.
pub const TOTAL_BLOCKS: usize = MAX_N * BLOCKS_PER_STEP;

// ─── Host-side reference implementations ─────────────────────────────────────

/// Build the 160-byte rolling root message.
///   layout: prev_root(32) ‖ index_le(32) ‖ receipt_hash(32) ‖ nullifier(32) ‖ adapter(32)
pub fn build_rolling_msg(
    prev_root: &[u8; 32],
    index: u64,
    receipt_hash: &[u8; 32],
    nullifier: &[u8; 32],
    adapter: &[u8; 32],
) -> [u8; 160] {
    let mut msg = [0u8; 160];
    msg[0..32].copy_from_slice(prev_root);
    msg[32..40].copy_from_slice(&index.to_le_bytes());
    // bytes 40..64 are zero padding for the index field
    msg[64..96].copy_from_slice(receipt_hash);
    msg[96..128].copy_from_slice(nullifier);
    msg[128..160].copy_from_slice(adapter);
    msg
}

/// SHA-256 of a 160-byte message (standard, single SHA-256 — NOT double).
/// Using single SHA-256 for m3 compatibility (the m3 gadget does single SHA-256).
pub fn sha256_160(data: &[u8; 160]) -> [u8; 32] {
    let h = Sha256::digest(data);
    let mut out = [0u8; 32];
    out.copy_from_slice(&h);
    out
}

/// Compute the rolling root chain for a list of receipts.
pub fn compute_rolling_root(
    capability_hash: &[u8; 32],
    receipts: &[ActiveReceipt],
) -> [u8; 32] {
    let mut root = *capability_hash;
    for r in receipts {
        let msg = build_rolling_msg(&root, r.index, &r.receipt_hash, &r.nullifier, &r.adapter);
        root = sha256_160(&msg);
    }
    root
}

/// Compute the full rolling root chain including zero-padded inactive slots.
pub fn compute_full_rolling_root(
    capability_hash: &[u8; 32],
    active_receipts: &[ActiveReceipt],
    total_slots: usize,
) -> [u8; 32] {
    let mut root = *capability_hash;
    for r in active_receipts {
        let msg = build_rolling_msg(&root, r.index, &r.receipt_hash, &r.nullifier, &r.adapter);
        root = sha256_160(&msg);
    }
    for _ in active_receipts.len()..total_slots {
        let msg = build_rolling_msg(&root, 0, &[0u8; 32], &[0u8; 32], &[0u8; 32]);
        root = sha256_160(&msg);
    }
    root
}

// ─── Witness types ───────────────────────────────────────────────────────────

/// A single active receipt's witness data.
pub struct ActiveReceipt {
    pub index: u64,
    pub receipt_hash: [u8; 32],
    pub nullifier: [u8; 32],
    pub adapter: [u8; 32],
    pub amount_in: u64,
    pub amount_out: u64,
}

/// Full witness for one compliance proof.
pub struct ComplianceInstance {
    pub capability_hash: [u8; 32],
    pub active_receipts: Vec<ActiveReceipt>,
}

impl ComplianceInstance {
    /// Deterministic test instance with n_active receipts.
    pub fn test_instance(n_active: usize) -> Self {
        assert!(n_active <= MAX_N);
        let capability_hash = [0xCAu8; 32];
        let mut active_receipts = Vec::with_capacity(n_active);
        for i in 0..n_active {
            active_receipts.push(ActiveReceipt {
                index: i as u64,
                receipt_hash: [0x10u8 + i as u8; 32],
                nullifier: [0x20u8 + i as u8; 32],
                adapter: {
                    let mut a = [0u8; 32];
                    a[12..32].copy_from_slice(&[0xABu8; 20]);
                    a
                },
                amount_in: 500_000_000,
                amount_out: 505_000_000,
            });
        }
        ComplianceInstance { capability_hash, active_receipts }
    }

    /// Convert the instance to SHA-256 message blocks for the m3 gadget.
    ///
    /// Each rolling root step produces 3 SHA-256 compression blocks:
    ///   Block 0: bytes  0–63 of the 160-byte message
    ///   Block 1: bytes 64–127
    ///   Block 2: bytes 128–159 + SHA-256 padding (0x80, length)
    ///
    /// Returns (blocks, final_root) where blocks is Vec<[u32; 16]>.
    pub fn to_sha256_blocks(&self) -> (Vec<[u32; 16]>, [u8; 32]) {
        let mut blocks = Vec::with_capacity(TOTAL_BLOCKS);
        let mut prev_root = self.capability_hash;

        let n_active = self.active_receipts.len();

        for i in 0..MAX_N {
            let (index, receipt_hash, nullifier, adapter) = if i < n_active {
                let r = &self.active_receipts[i];
                (r.index, r.receipt_hash, r.nullifier, r.adapter)
            } else {
                (0u64, [0u8; 32], [0u8; 32], [0u8; 32])
            };

            let msg = build_rolling_msg(&prev_root, index, &receipt_hash, &nullifier, &adapter);

            // Pad the 160-byte message to SHA-256 blocks.
            // SHA-256 processes 64-byte (512-bit) blocks.
            // 160 bytes → 3 blocks (160 + 1 + padding + 8 length = 192 bytes = 3 blocks)
            let mut padded = [0u8; 192]; // 3 × 64
            padded[..160].copy_from_slice(&msg);
            padded[160] = 0x80; // SHA-256 padding bit
            // Length in bits (big-endian) at the end of the last block
            let bit_len: u64 = 160 * 8;
            padded[184..192].copy_from_slice(&bit_len.to_be_bytes());

            // Convert each 64-byte block to [u32; 16] (big-endian, as SHA-256 expects)
            for block_idx in 0..3 {
                let offset = block_idx * 64;
                let mut block = [0u32; 16];
                for w in 0..16 {
                    let b = offset + w * 4;
                    block[w] = u32::from_be_bytes([
                        padded[b], padded[b + 1], padded[b + 2], padded[b + 3],
                    ]);
                }
                blocks.push(block);
            }

            // Compute the actual SHA-256 for the next step's prev_root
            prev_root = sha256_160(&msg);
        }

        (blocks, prev_root)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rolling_root_deterministic() {
        let cap = [0xCAu8; 32];
        let rh = [0x10u8; 32];
        let nf = [0x20u8; 32];
        let adapter = [0xABu8; 32];

        let msg = build_rolling_msg(&cap, 0, &rh, &nf, &adapter);
        let r1 = sha256_160(&msg);
        let r2 = sha256_160(&msg);
        assert_eq!(r1, r2);
        assert_ne!(r1, cap);
    }

    #[test]
    fn test_rolling_root_chain_changes() {
        let cap = [0xCAu8; 32];
        let rh = [0x10u8; 32];
        let nf = [0x20u8; 32];
        let adapter = [0xABu8; 32];

        let msg1 = build_rolling_msg(&cap, 0, &rh, &nf, &adapter);
        let r1 = sha256_160(&msg1);

        let msg2 = build_rolling_msg(&r1, 1, &[0x11u8; 32], &[0x21u8; 32], &adapter);
        let r2 = sha256_160(&msg2);
        assert_ne!(r1, r2);
    }

    #[test]
    fn test_sha256_blocks_count() {
        let inst = ComplianceInstance::test_instance(4);
        let (blocks, _root) = inst.to_sha256_blocks();
        assert_eq!(blocks.len(), TOTAL_BLOCKS);
    }

    #[test]
    fn test_full_root_matches_reference() {
        let inst = ComplianceInstance::test_instance(4);
        let expected = compute_full_rolling_root(
            &inst.capability_hash,
            &inst.active_receipts,
            MAX_N,
        );
        let (_blocks, actual) = inst.to_sha256_blocks();
        assert_eq!(actual, expected);
    }

    #[test]
    fn test_zero_active() {
        let inst = ComplianceInstance::test_instance(0);
        let (blocks, root) = inst.to_sha256_blocks();
        assert_eq!(blocks.len(), TOTAL_BLOCKS);
        assert_ne!(root, inst.capability_hash);
    }

    #[test]
    fn test_full_active() {
        let inst = ComplianceInstance::test_instance(MAX_N);
        let (blocks, root) = inst.to_sha256_blocks();
        assert_eq!(blocks.len(), TOTAL_BLOCKS);
        let expected = compute_full_rolling_root(
            &inst.capability_hash,
            &inst.active_receipts,
            MAX_N,
        );
        assert_eq!(root, expected);
    }
}
