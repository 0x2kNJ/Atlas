// Settle Circuit (binius64 research implementation)
//
// Identical structure to Spend but uses DOMAIN_SETTLE for the nullifier,
// preventing replay across operation types.
//
// SHA256 compression rounds: 69 (same as Spend)

use binius_circuits::bitcoin::double_sha256::DoubleSha256;
use binius_core::word::Word;
use binius_frontend::{CircuitBuilder, Wire, WitnessFiller, util::pack_bytes_into_wires_le};

use crate::common::{
    DOMAIN_SETTLE, MERKLE_DEPTH, MerklePath, SiblingSide,
    add_public_hash, add_witness_hash, assert_gte,
    build_test_merkle_path, fill_hash_le,
    note_commitment, nullifier,
};

pub struct SettleCircuit {
    in_commitment_sha: DoubleSha256,
    in_commitment_msg: Vec<Wire>,
    nullifier_sha: DoubleSha256,
    nullifier_msg: Vec<Wire>,
    merkle_path: MerklePath,
    sibling_wires: Vec<[Wire; 4]>,
    side_bit_wires: Vec<Wire>,
    merkle_length_wire: Wire,
    out_commitment_sha: DoubleSha256,
    out_commitment_msg: Vec<Wire>,
    in_note_value_wire: Wire,
    out_note_value_wire: Wire,
    cm_in_wires: [Wire; 4],
    merkle_root_wires: [Wire; 4],
    nf_wires: [Wire; 4],
    cm_out_wires: [Wire; 4],
}

impl SettleCircuit {
    pub fn build(builder: &mut CircuitBuilder) -> Self {
        let cm_in_wires = add_public_hash(builder);
        let merkle_root_wires = add_public_hash(builder);
        let nf_wires = add_public_hash(builder);
        let cm_out_wires = add_public_hash(builder);
        let in_note_value_wire = builder.add_witness();
        let out_note_value_wire = builder.add_witness();

        let in_msg: Vec<Wire> = (0..9).map(|_| builder.add_witness()).collect();
        let in_commitment_sha = DoubleSha256::construct_circuit(builder, in_msg.clone(), cm_in_wires);
        builder.assert_eq("in_msg[0] = in_value", in_msg[0], in_note_value_wire);

        let nf_msg: Vec<Wire> = (0..8).map(|_| builder.add_witness()).collect();
        let nullifier_sha = DoubleSha256::construct_circuit(builder, nf_msg.clone(), nf_wires);

        let mut sibling_wires: Vec<[Wire; 4]> = Vec::new();
        let mut side_bit_wires: Vec<Wire> = Vec::new();
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
            builder, cm_in_wires, siblings, merkle_root_wires, merkle_length_wire,
        );

        let out_msg: Vec<Wire> = (0..9).map(|_| builder.add_witness()).collect();
        let out_commitment_sha = DoubleSha256::construct_circuit(builder, out_msg.clone(), cm_out_wires);
        builder.assert_eq("out_msg[0] = out_value", out_msg[0], out_note_value_wire);

        assert_gte(builder, in_note_value_wire, out_note_value_wire);

        SettleCircuit {
            in_commitment_sha, in_commitment_msg: in_msg,
            nullifier_sha, nullifier_msg: nf_msg,
            merkle_path, sibling_wires, side_bit_wires, merkle_length_wire,
            out_commitment_sha, out_commitment_msg: out_msg,
            in_note_value_wire, out_note_value_wire,
            cm_in_wires, merkle_root_wires, nf_wires, cm_out_wires,
        }
    }

    pub fn populate(
        &self,
        filler: &mut WitnessFiller,
        in_value: u64, in_rand: [u8; 32], in_pk: [u8; 32],
        out_value: u64, out_rand: [u8; 32], out_pk: [u8; 32],
    ) {
        let cm_in = note_commitment(in_value, &in_rand, &in_pk);
        let nf = nullifier(&in_rand, &DOMAIN_SETTLE);
        let cm_out = note_commitment(out_value, &out_rand, &out_pk);
        let (root, path) = build_test_merkle_path(cm_in, MERKLE_DEPTH);

        fill_hash_le(filler, self.cm_in_wires, &cm_in);
        fill_hash_le(filler, self.merkle_root_wires, &root);
        fill_hash_le(filler, self.nf_wires, &nf);
        fill_hash_le(filler, self.cm_out_wires, &cm_out);
        filler[self.in_note_value_wire] = Word(in_value);
        filler[self.out_note_value_wire] = Word(out_value);

        let mut cm_msg = [0u8; 72];
        cm_msg[..8].copy_from_slice(&in_value.to_le_bytes());
        cm_msg[8..40].copy_from_slice(&in_rand);
        cm_msg[40..72].copy_from_slice(&in_pk);
        pack_bytes_into_wires_le(filler, &self.in_commitment_msg, &cm_msg);
        self.in_commitment_sha.populate_inner(filler, &cm_msg);

        let mut nf_msg = [0u8; 64];
        nf_msg[..32].copy_from_slice(&in_rand);
        nf_msg[32..].copy_from_slice(&DOMAIN_SETTLE);
        pack_bytes_into_wires_le(filler, &self.nullifier_msg, &nf_msg);
        self.nullifier_sha.populate_inner(filler, &nf_msg);

        filler[self.merkle_length_wire] = Word(MERKLE_DEPTH as u64);
        for (i, (sib, side)) in path.iter().enumerate() {
            fill_hash_le(filler, self.sibling_wires[i], sib);
            filler[self.side_bit_wires[i]] = match side {
                SiblingSide::Left  => Word::ZERO,
                SiblingSide::Right => Word::ALL_ONE,
            };
        }
        self.merkle_path.populate_inner(filler, cm_in, &path);

        let mut out_cm_msg = [0u8; 72];
        out_cm_msg[..8].copy_from_slice(&out_value.to_le_bytes());
        out_cm_msg[8..40].copy_from_slice(&out_rand);
        out_cm_msg[40..72].copy_from_slice(&out_pk);
        pack_bytes_into_wires_le(filler, &self.out_commitment_msg, &out_cm_msg);
        self.out_commitment_sha.populate_inner(filler, &out_cm_msg);
    }
}
