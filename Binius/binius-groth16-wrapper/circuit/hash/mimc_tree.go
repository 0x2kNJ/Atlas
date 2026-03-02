// Package hash provides ZK-friendly hash gadgets for the binius64 wrapper circuit.
//
// # Why MiMC instead of SHA256 for Merkle hashing
//
// SHA256 inside a PLONK circuit costs ~25,000 constraints per invocation (one
// compression block).  A depth-20 Merkle path therefore costs 500,000
// constraints per FRI query, and with 232 queries across 100 proofs the total
// Merkle cost alone is ~11.6 billion constraints.
//
// MiMC-BN254 (Miyaguchi-Preneel over the BN254 scalar field) costs ~340
// constraints per 2-input call.  The same depth-20 path costs ~6,800
// constraints — a 74× improvement.  The full circuit drops from ~15.7B to
// ~1.4B constraints, bringing N=100 batch proving time from hours to roughly
// 12 minutes on a server GPU.
//
// # Protocol note
//
// Switching to MiMC Merkle is a coordinated protocol change: the binius64 Rust
// prover and the BiniusBatchVerifier.sol must both use MiMC for tree hashing.
// The Fiat-Shamir transcript (sumcheck challenges, fold challenges) continues
// to use SHA256 for compatibility with the existing binius HasherChallenger
// specification.
//
// # MiMC-BN254 specification
//
// The MiMC gadget in gnark implements MiMC-BN254 (also called MiMC7-BN254 in
// the gnark-crypto library).  The Miyaguchi-Preneel mode feeds each input
// element through the cipher and XORs with the running state:
//
//	state_0    = 0   (zero initialisation, no key)
//	state_{i+1} = MiMC_encrypt(state_i, data_i) ⊕ state_i ⊕ data_i
//
// The Go-side counterpart is github.com/consensys/gnark-crypto/ecc/bn254/fr/mimc.
package hash

import (
	"math/big"

	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/std/hash/mimc"
	"github.com/consensys/gnark/std/math/uints"

	"github.com/envelopes/binius-groth16-wrapper/circuit/gf128"
)

// shift64 = 2^64 as a constant for packing GF128 Lo/Hi limbs into one field element.
var shift64 = new(big.Int).Lsh(big.NewInt(1), 64)

// PackGF128 packs a GF(2^128) element into a single BN254 field variable.
//
// Representation: packed = Lo_u64 + Hi_u64 · 2^64
//
// Both Lo and Hi are 64-bit, so packed ∈ [0, 2^128 − 1] ⊂ BN254 field. ✓
// The linear combination is constraint-free (constant coefficients).
func PackGF128(api frontend.API, uapi *uints.BinaryField[uints.U64], v gf128.GF128) frontend.Variable {
	loVar := U64ToFieldVar(api, uapi, v.Lo)
	hiVar := U64ToFieldVar(api, uapi, v.Hi)
	return api.Add(loVar, api.Mul(hiVar, shift64))
}

// U64ToFieldVar converts a uints.U64 to a single BN254 field variable.
//
// Reconstruction: Σ bytes[i] · 256^i  (little-endian, constant coefficients).
// Because the coefficients 256^i are compile-time constants, gnark folds the
// entire sum into a single linear constraint row — effectively zero overhead.
func U64ToFieldVar(api frontend.API, uapi *uints.BinaryField[uints.U64], v uints.U64) frontend.Variable {
	bytes := uapi.UnpackLSB(v) // 8 bytes, LSB first
	result := bytes[0].Val
	shift := big.NewInt(1)
	for i := 1; i < 8; i++ {
		shift.Lsh(shift, 8) // shift *= 256
		s := new(big.Int).Set(shift)
		result = api.Add(result, api.Mul(bytes[i].Val, s))
	}
	return result
}

// HashLeafMiMC hashes 16 GF(2^128) coset values into a single BN254 field
// element using MiMC-BN254.
//
// Each GF128 element is packed into one field variable via PackGF128 before
// being written to the hasher.  The MiMC Miyaguchi-Preneel chain processes
// all 16 elements sequentially.
//
// Constraint cost: 16 × ~340 ≈ 5,440 PLONK constraints.
// Compare: SHA256(256 bytes) ≈ 125,000 constraints.
func HashLeafMiMC(
	api frontend.API,
	uapi *uints.BinaryField[uints.U64],
	vals [16]gf128.GF128,
) (frontend.Variable, error) {
	h, err := mimc.NewMiMC(api)
	if err != nil {
		return nil, err
	}
	for _, v := range vals {
		packed := PackGF128(api, uapi, v)
		h.Write(packed)
	}
	return h.Sum(), nil
}

// HashNodeMiMC computes an internal Merkle node from two child hashes using
// MiMC-BN254.  Both children are field elements (outputs of HashLeafMiMC or
// prior HashNodeMiMC calls).
//
// Constraint cost: ~340 PLONK constraints.
// Compare: BiniusCompress (SHA256 block) ≈ 25,000 constraints.
func HashNodeMiMC(api frontend.API, left, right frontend.Variable) (frontend.Variable, error) {
	h, err := mimc.NewMiMC(api)
	if err != nil {
		return nil, err
	}
	h.Write(left, right)
	return h.Sum(), nil
}

// FieldElementToBytes decomposes a BN254 field element into 32 bytes in
// little-endian order.  The field element has 254 significant bits; the
// remaining 2 bits of the 256-bit representation are zero.
//
// Used by the SHA256 transcript to absorb a MiMC tree root.
// Constraint cost: ~280 constraints (254 ToBinary + 32 FromBinary).
func FieldElementToBytes(api frontend.API, val frontend.Variable) [32]uints.U8 {
	bits := api.ToBinary(val, 254) // 254 bits, LSB first
	var out [32]uints.U8
	for byteIdx := 0; byteIdx < 32; byteIdx++ {
		var byteBits [8]frontend.Variable
		for bitIdx := 0; bitIdx < 8; bitIdx++ {
			pos := byteIdx*8 + bitIdx
			if pos < 254 {
				byteBits[bitIdx] = bits[pos]
			} else {
				byteBits[bitIdx] = frontend.Variable(0)
			}
		}
		out[byteIdx] = uints.U8{Val: api.FromBinary(byteBits[:]...)}
	}
	return out
}
