// Encumber Circuit (binius64 research implementation)
//
// Proves:
//   1. Note commitment: cm(N) = DoubleSha256(note_value || note_rand || owner_pk)  [72 bytes]
//   2. Merkle membership: MerklePath with depth=20 using DoubleSha256 per step
//   3. Nullifier: nf = DoubleSha256(note_rand || DOMAIN_ENCUMBER)  [64 bytes]
//   4. Collateral sufficiency: note_value >= collateral_amount  [u64 comparison]
//
// All external hash wires are in LE format (consistent with MerklePath).
// DoubleSha256 = SHA256∘SHA256 — ~1.5× more rounds than single SHA256.
//
// SHA256 compression round count:
//   Note commitment:       3  (DoubleSha256 of 72 bytes)
//   Nullifier:             3  (DoubleSha256 of 64 bytes)
//   Merkle path (×20):    60  (DoubleSha256 of 64 bytes per step)
//   Range check:           ~0
//   Total:                66 SHA256 compression rounds

use binius_circuits::bitcoin::double_sha256::DoubleSha256;
use binius_core::word::Word;
use binius_frontend::{CircuitBuilder, Wire, WitnessFiller, util::pack_bytes_into_wires_le};

use crate::common::{
    DOMAIN_ENCUMBER, MERKLE_DEPTH, MerklePath, SiblingSide,
    add_public_hash, add_witness_hash, assert_gte,
    build_test_merkle_path, fill_hash_le,
    note_commitment, nullifier,
};

pub struct EncumberCircuit {
    // DoubleSha256 gadget for note commitment (72-byte message, 9 wires)
    commitment_sha: DoubleSha256,
    commitment_msg_wires: Vec<Wire>, // 9 LE wires (72 bytes / 8)

    // DoubleSha256 gadget for nullifier (64-byte message, 8 wires)
    nullifier_sha: DoubleSha256,
    nullifier_msg_wires: Vec<Wire>, // 8 LE wires

    // Merkle path gadget (DoubleSha256 per step, depth 20)
    merkle_path: MerklePath,
    sibling_wires: Vec<[Wire; 4]>,
    side_bit_wires: Vec<Wire>,
    merkle_length_wire: Wire,

    // Public I/O wires
    cm_n_wires: [Wire; 4],     // note commitment (LE)
    nf_wires: [Wire; 4],       // encumber nullifier (LE)
    merkle_root_wires: [Wire; 4], // Merkle root (LE)
    collateral_amount_wire: Wire,

    // Private witness for range check
    note_value_wire: Wire,
}

impl EncumberCircuit {
    pub fn build(builder: &mut CircuitBuilder) -> Self {
        // ── Public inputs ────────────────────────────────────────────────────
        let cm_n_wires = add_public_hash(builder);
        let merkle_root_wires = add_public_hash(builder);
        let nf_wires = add_public_hash(builder);
        let collateral_amount_wire = builder.add_inout();

        // ── Private: note value for range check ──────────────────────────────
        let note_value_wire = builder.add_witness();

        // ── Constraint 1: Note commitment ────────────────────────────────────
        // message = note_value(8) || note_rand(32) || owner_pk(32) = 72 bytes = 9 wires
        let commitment_msg_wires: Vec<Wire> = (0..9).map(|_| builder.add_witness()).collect();
        let commitment_sha = DoubleSha256::construct_circuit(
            builder,
            commitment_msg_wires.clone(),
            cm_n_wires,
        );
        // Tie msg[0] (note_value wire in LE format) to note_value_wire for range check.
        // The note_value occupies bytes 0-7 of the message in LE order:
        //   wire[0] = u64::from_le_bytes([note_value bytes]) = the note_value itself
        builder.assert_eq("cm_msg[0] = note_value", commitment_msg_wires[0], note_value_wire);

        // ── Constraint 2: Nullifier ──────────────────────────────────────────
        // message = note_rand(32) || DOMAIN_ENCUMBER(32) = 64 bytes = 8 wires
        let nullifier_msg_wires: Vec<Wire> = (0..8).map(|_| builder.add_witness()).collect();
        let nullifier_sha = DoubleSha256::construct_circuit(
            builder,
            nullifier_msg_wires.clone(),
            nf_wires,
        );

        // ── Constraint 3: Merkle path ────────────────────────────────────────
        let mut sibling_wires: Vec<[Wire; 4]> = Vec::with_capacity(MERKLE_DEPTH);
        let mut side_bit_wires: Vec<Wire> = Vec::with_capacity(MERKLE_DEPTH);
        let siblings: Vec<([Wire; 4], Wire)> = (0..MERKLE_DEPTH)
            .map(|_| {
                let sw = add_witness_hash(builder);
                let bit = builder.add_witness();
                sibling_wires.push(sw);
                side_bit_wires.push(bit);
                (sw, bit)
            })
            .collect();

        let merkle_length_wire = builder.add_witness();
        let merkle_path = MerklePath::construct_circuit(
            builder,
            cm_n_wires, // leaf = note commitment
            siblings,
            merkle_root_wires,
            merkle_length_wire,
        );

        // ── Constraint 4: LTV range check ────────────────────────────────────
        assert_gte(builder, note_value_wire, collateral_amount_wire);

        EncumberCircuit {
            commitment_sha,
            commitment_msg_wires,
            nullifier_sha,
            nullifier_msg_wires,
            merkle_path,
            sibling_wires,
            side_bit_wires,
            merkle_length_wire,
            cm_n_wires,
            nf_wires,
            merkle_root_wires,
            collateral_amount_wire,
            note_value_wire,
        }
    }

    pub fn populate(
        &self,
        filler: &mut WitnessFiller,
        note_value: u64,
        note_rand: [u8; 32],
        owner_pk: [u8; 32],
        collateral_amount: u64,
    ) {
        // Compute all derived values
        let cm_n = note_commitment(note_value, &note_rand, &owner_pk);
        let nf = nullifier(&note_rand, &DOMAIN_ENCUMBER);
        let (root, path) = build_test_merkle_path(cm_n, MERKLE_DEPTH);

        // ── Public outputs ────────────────────────────────────────────────────
        fill_hash_le(filler, self.cm_n_wires, &cm_n);
        fill_hash_le(filler, self.nf_wires, &nf);
        fill_hash_le(filler, self.merkle_root_wires, &root);
        filler[self.collateral_amount_wire] = Word(collateral_amount);

        // ── Note value (private) ─────────────────────────────────────────────
        filler[self.note_value_wire] = Word(note_value);

        // ── Commitment message wires ─────────────────────────────────────────
        // Pack 72 bytes (value||rand||pk) into 9 LE wires
        let mut cm_msg = [0u8; 72];
        cm_msg[..8].copy_from_slice(&note_value.to_le_bytes());
        cm_msg[8..40].copy_from_slice(&note_rand);
        cm_msg[40..72].copy_from_slice(&owner_pk);
        pack_bytes_into_wires_le(filler, &self.commitment_msg_wires, &cm_msg);
        self.commitment_sha.populate_inner(filler, &cm_msg);

        // ── Nullifier message wires ───────────────────────────────────────────
        let mut nf_msg = [0u8; 64];
        nf_msg[..32].copy_from_slice(&note_rand);
        nf_msg[32..].copy_from_slice(&DOMAIN_ENCUMBER);
        pack_bytes_into_wires_le(filler, &self.nullifier_msg_wires, &nf_msg);
        self.nullifier_sha.populate_inner(filler, &nf_msg);

        // ── Merkle path ───────────────────────────────────────────────────────
        filler[self.merkle_length_wire] = Word(MERKLE_DEPTH as u64);
        for (i, (sib, side)) in path.iter().enumerate() {
            fill_hash_le(filler, self.sibling_wires[i], sib);
            filler[self.side_bit_wires[i]] = match side {
                SiblingSide::Left  => Word::ZERO,
                SiblingSide::Right => Word::ALL_ONE,
            };
        }
        self.merkle_path.populate_inner(filler, cm_n, &path);
    }
}

pub struct EncumberInstance {
    pub note_value: u64,
    pub note_rand: [u8; 32],
    pub owner_pk: [u8; 32],
    pub collateral_amount: u64,
}

impl EncumberInstance {
    pub fn test_instance() -> Self {
        EncumberInstance {
            note_value: 100_000_000,
            note_rand: [0x42u8; 32],
            owner_pk: [0x11u8; 32],
            collateral_amount: 75_000_000,
        }
    }
}
