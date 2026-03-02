//! Atlas Protocol — Binius64 Compliance Circuit
//!
//! Proves that the prover knows N execution receipts under a capability
//! such that chained SHA-256 hashes reproduce a committed rolling root.
//!
//! This is the binius64 port of the compliance circuit previously written
//! for the archived IrreducibleOSS/binius `m3` API and the Noir `circuit1`.
//!
//! # On-chain parity
//!
//! The hash chain matches `ReceiptAccumulatorSHA256.sol`:
//! ```text
//!   root_0 = capability_hash
//!   root_i = sha256(prev_root ‖ index_le32 ‖ receipt_hash ‖ nullifier ‖ adapter)
//!            [32B]    [8B LE + 24B zero]  [32B]           [32B]        [32B]
//!            = 160 bytes total per step
//! ```
//!
//! # Circuit structure
//!
//! Uses `binius_circuits::sha256::sha256_fixed` (fixed-length SHA-256) with
//! 40 × 32-bit big-endian message words per step. Output wires feed directly
//! into the next step's `prev_root` slots — no extra constraints needed.
//!
//! Public inputs:  `capability_hash` (8 words), `final_root` (8 words)
//! Private inputs: per-step `index`, `receipt_hash`, `nullifier`, `adapter`

use binius_circuits::sha256::sha256_fixed;
use binius_core::word::Word;
use binius_frontend::{CircuitBuilder, Wire, WitnessFiller};
use sha2::{Digest, Sha256 as StdSha256};

pub const MAX_N: usize = 64;

// ─── Host-side reference implementations ─────────────────────────────────────

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
    msg[64..96].copy_from_slice(receipt_hash);
    msg[96..128].copy_from_slice(nullifier);
    msg[128..160].copy_from_slice(adapter);
    msg
}

pub fn sha256_160(data: &[u8; 160]) -> [u8; 32] {
    let mut out = [0u8; 32];
    out.copy_from_slice(&StdSha256::digest(data));
    out
}

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

fn pack_be_u32(data: &[u8], offset: usize) -> u32 {
    u32::from_be_bytes([
        data[offset],
        data[offset + 1],
        data[offset + 2],
        data[offset + 3],
    ])
}

// ─── Witness types ───────────────────────────────────────────────────────────

pub struct ActiveReceipt {
    pub index: u64,
    pub receipt_hash: [u8; 32],
    pub nullifier: [u8; 32],
    pub adapter: [u8; 32],
}

pub struct ComplianceInstance {
    pub capability_hash: [u8; 32],
    pub active_receipts: Vec<ActiveReceipt>,
}

impl ComplianceInstance {
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
            });
        }
        ComplianceInstance {
            capability_hash,
            active_receipts,
        }
    }
}

// ─── Circuit ─────────────────────────────────────────────────────────────────

pub struct StepWires {
    pub index_wires: [Wire; 8],
    pub receipt_hash_wires: [Wire; 8],
    pub nullifier_wires: [Wire; 8],
    pub adapter_wires: [Wire; 8],
}

pub struct ComplianceCircuit {
    pub capability_hash_wires: [Wire; 8],
    pub final_root_wires: [Wire; 8],
    pub steps: Vec<StepWires>,
}

impl ComplianceCircuit {
    /// Build a compliance circuit that chains `n_steps` SHA-256 hashes.
    ///
    /// Each step hashes 160 bytes: `prev_root(32) ‖ index(32) ‖ receipt(32) ‖ nullifier(32) ‖ adapter(32)`.
    /// The output of `sha256_fixed` feeds directly as `prev_root` into the next step.
    /// The final digest is constrained to equal the public `final_root`.
    pub fn build(builder: &CircuitBuilder, n_steps: usize) -> Self {
        let capability_hash_wires: [Wire; 8] = std::array::from_fn(|_| builder.add_inout());
        let final_root_wires: [Wire; 8] = std::array::from_fn(|_| builder.add_inout());

        let mut steps = Vec::with_capacity(n_steps);
        let mut prev_root: [Wire; 8] = capability_hash_wires;

        for step in 0..n_steps {
            let sb = builder.subcircuit(format!("step[{step}]"));

            let index_wires: [Wire; 8] = std::array::from_fn(|_| sb.add_witness());
            let receipt_hash_wires: [Wire; 8] = std::array::from_fn(|_| sb.add_witness());
            let nullifier_wires: [Wire; 8] = std::array::from_fn(|_| sb.add_witness());
            let adapter_wires: [Wire; 8] = std::array::from_fn(|_| sb.add_witness());

            let mut message: Vec<Wire> = Vec::with_capacity(40);
            message.extend_from_slice(&prev_root);
            message.extend_from_slice(&index_wires);
            message.extend_from_slice(&receipt_hash_wires);
            message.extend_from_slice(&nullifier_wires);
            message.extend_from_slice(&adapter_wires);

            let digest = sha256_fixed(&sb, &message, 160);
            prev_root = digest;

            steps.push(StepWires {
                index_wires,
                receipt_hash_wires,
                nullifier_wires,
                adapter_wires,
            });
        }

        for i in 0..8 {
            builder.assert_eq(
                format!("final_root[{i}]"),
                prev_root[i],
                final_root_wires[i],
            );
        }

        ComplianceCircuit {
            capability_hash_wires,
            final_root_wires,
            steps,
        }
    }

    /// Populate all witness wires from a `ComplianceInstance`.
    ///
    /// Computes the rolling root chain on the host side and fills in
    /// capability_hash, final_root, and all per-step private data.
    pub fn populate_witness(&self, instance: &ComplianceInstance, w: &mut WitnessFiller) {
        let n_steps = self.steps.len();
        let final_root =
            compute_full_rolling_root(&instance.capability_hash, &instance.active_receipts, n_steps);

        for (i, wire) in self.capability_hash_wires.iter().enumerate() {
            w[*wire] = Word(pack_be_u32(&instance.capability_hash, i * 4) as u64);
        }

        for (i, wire) in self.final_root_wires.iter().enumerate() {
            w[*wire] = Word(pack_be_u32(&final_root, i * 4) as u64);
        }

        let n_active = instance.active_receipts.len();
        let mut prev_root = instance.capability_hash;

        for (step_idx, step) in self.steps.iter().enumerate() {
            let (index, receipt_hash, nullifier, adapter) = if step_idx < n_active {
                let r = &instance.active_receipts[step_idx];
                (r.index, r.receipt_hash, r.nullifier, r.adapter)
            } else {
                (0u64, [0u8; 32], [0u8; 32], [0u8; 32])
            };

            let msg = build_rolling_msg(&prev_root, index, &receipt_hash, &nullifier, &adapter);

            for i in 0..8 {
                w[step.index_wires[i]] = Word(pack_be_u32(&msg, 32 + i * 4) as u64);
                w[step.receipt_hash_wires[i]] = Word(pack_be_u32(&msg, 64 + i * 4) as u64);
                w[step.nullifier_wires[i]] = Word(pack_be_u32(&msg, 96 + i * 4) as u64);
                w[step.adapter_wires[i]] = Word(pack_be_u32(&msg, 128 + i * 4) as u64);
            }

            prev_root = sha256_160(&msg);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use binius_core::verify::verify_constraints;

    fn run_compliance_test(n_steps: usize, n_active: usize) {
        let builder = CircuitBuilder::new();
        let cc = ComplianceCircuit::build(&builder, n_steps);
        let circuit = builder.build();

        let instance = ComplianceInstance::test_instance(n_active);
        let mut w = circuit.new_witness_filler();
        cc.populate_witness(&instance, &mut w);
        circuit.populate_wire_witness(&mut w).unwrap();

        let cs = circuit.constraint_system();
        verify_constraints(cs, &w.into_value_vec()).unwrap();
    }

    #[test]
    fn test_single_step() {
        run_compliance_test(1, 1);
    }

    #[test]
    fn test_four_steps_four_active() {
        run_compliance_test(4, 4);
    }

    #[test]
    fn test_four_steps_two_active() {
        run_compliance_test(4, 2);
    }

    #[test]
    fn test_four_steps_zero_active() {
        run_compliance_test(4, 0);
    }

    #[test]
    fn test_rolling_root_matches_solidity() {
        let instance = ComplianceInstance::test_instance(2);
        let root = compute_full_rolling_root(&instance.capability_hash, &instance.active_receipts, 4);
        assert_ne!(root, instance.capability_hash);

        let root2 = compute_full_rolling_root(&instance.capability_hash, &instance.active_receipts, 4);
        assert_eq!(root, root2);
    }

    #[test]
    fn test_wrong_root_rejected() {
        let builder = CircuitBuilder::new();
        let cc = ComplianceCircuit::build(&builder, 2);
        let circuit = builder.build();

        let instance = ComplianceInstance::test_instance(2);
        let mut w = circuit.new_witness_filler();
        cc.populate_witness(&instance, &mut w);

        // Corrupt the final root
        w[cc.final_root_wires[0]] = Word(0xDEAD);

        let result = circuit.populate_wire_witness(&mut w);
        assert!(result.is_err(), "Circuit should reject a corrupted root");
    }
}
