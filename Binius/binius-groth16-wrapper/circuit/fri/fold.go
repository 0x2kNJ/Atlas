// Package fri implements the FRI fold verification gadget for binius64,
// mirroring FRIFold.sol exactly.
//
// Key design choices vs. the previous version:
//  - Twiddle factors are computed IN-CIRCUIT from the precomputed basis table
//    (hardcoded constants), matching _twiddle/_twiddleBasis in FRIFold.sol.
//    The prover no longer supplies twiddle witnesses that could be forged.
//  - The fold-pair formula matches _foldPair in FRIFold.sol exactly:
//      v' = u XOR v
//      u' = u XOR GF128mul(v', t)
//      result = u' XOR GF128mul(r, v' XOR u')
//  - cosetToBytes serialises GF128 elements as [Hi_BE | Lo_BE] to match
//    the Solidity _hashCoset bswap128 semantic (byte-reversed 128-bit value).
package fri

import (
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/std/math/uints"

	"github.com/envelopes/binius-groth16-wrapper/circuit/compress"
	"github.com/envelopes/binius-groth16-wrapper/circuit/gf128"
	circuithash "github.com/envelopes/binius-groth16-wrapper/circuit/hash"
	"github.com/envelopes/binius-groth16-wrapper/circuit/merkle"
	"github.com/envelopes/binius-groth16-wrapper/circuit/transcript"
)

// CosetSize is the number of GF128 values opened per FRI query (= 2^log_batch_size = 16).
const CosetSize = 16

// NumFoldChallenges is log2(CosetSize) = 4.
const NumFoldChallenges = 4

// QueryWitness is the private witness for a single FRI query.
// Uses SHA256/BiniusCompress for Merkle hashing (compatibility path).
type QueryWitness struct {
	// CosetValues: 16 GF128 field elements opened at this query position.
	CosetValues [CosetSize]gf128.GF128

	// ChunkIndex: which coset was opened (circuit variable, sampled from transcript).
	ChunkIndex frontend.Variable

	// AuthPath: Merkle authentication path for the coset hash (SHA256 bytes).
	AuthPath merkle.Path
}

// MiMCQueryWitness is the private witness for a single FRI query using
// MiMC-BN254 for leaf hashing and Merkle path authentication.
//
// Replacing SHA256/BiniusCompress with MiMC reduces constraint cost:
//   - Leaf hash:     ~5,440 constraints  (was ~125,000 — 23× cheaper)
//   - Merkle path:   ~6,800 constraints  (was ~500,000 — 74× cheaper per depth-20 path)
//   - Total per query: ~35,000 constraints (was ~673,000 — ~19× reduction)
type MiMCQueryWitness struct {
	// CosetValues: 16 GF128 field elements opened at this query position.
	CosetValues [CosetSize]gf128.GF128

	// ChunkIndex: which coset was opened (circuit variable, sampled from transcript).
	ChunkIndex frontend.Variable

	// AuthPath: Merkle authentication path using MiMC field-element hashes.
	AuthPath merkle.FieldPath
}

// Verifier holds shared state for FRI query verification.
type Verifier struct {
	api   frontend.API
	uapi  *uints.BinaryField[uints.U64]
	gfGad *gf128.Gadget
}

// NewVerifier creates a new FRI verifier gadget.
func NewVerifier(api frontend.API, gfGad *gf128.Gadget) (*Verifier, error) {
	uapi, err := uints.New[uints.U64](api)
	if err != nil {
		return nil, err
	}
	return &Verifier{api: api, uapi: uapi, gfGad: gfGad}, nil
}

// FoldChunk folds CosetSize values into a single GF128 via 4 butterfly steps,
// matching FRIFold.foldChunk exactly.
//
// chunkIndex is a circuit variable giving the coset position in the oracle.
// logLen is a compile-time constant (14 for oracle1, 10 for oracle2).
// Fold challenges must be sampled ONCE per proof (not per query) from the
// Fiat-Shamir transcript before calling this function.
func (v *Verifier) FoldChunk(
	values [CosetSize]gf128.GF128,
	challenges [NumFoldChallenges]gf128.GF128,
	chunkIndex frontend.Variable,
	logLen int, // compile-time constant
) gf128.GF128 {
	// Decompose chunkIndex into bits.  At logLen=14, cosets = 2^(14-4) = 1024 → 10 bits.
	// At logLen=10, cosets = 2^(10-4) = 64 → 6 bits.
	numChunkBits := logLen - NumFoldChallenges
	if numChunkBits < 0 {
		numChunkBits = 0
	}
	chunkBits := v.api.ToBinary(chunkIndex, numChunkBits)

	current := make([]gf128.GF128, CosetSize)
	copy(current, values[:])

	logSize := NumFoldChallenges // = 4 initially
	curLogLen := logLen

	for step := 0; step < NumFoldChallenges; step++ {
		chal := challenges[step]
		halfSize := 1 << (logSize - 1) // 8, 4, 2, 1
		layer := curLogLen - 1          // twiddle layer for this step
		chunkShift := logSize - 1       // how many lower bits are indexOffset

		next := make([]gf128.GF128, halfSize)
		for indexOffset := 0; indexOffset < halfSize; indexOffset++ {
			u := current[2*indexOffset]
			w := current[2*indexOffset+1]

			tw := v.computeTwiddle(layer, chunkBits, chunkShift, indexOffset, numChunkBits)
			next[indexOffset] = foldPair(v.gfGad, u, w, tw, chal)
		}

		current = next
		curLogLen--
		logSize--
	}

	return current[0]
}

// foldPair implements _foldPair from FRIFold.sol:
//
//	v' = u XOR v
//	u' = u XOR GF128mul(v', t)
//	return u' XOR GF128mul(r, v' XOR u')
func foldPair(gfGad *gf128.Gadget, u, w, t, r gf128.GF128) gf128.GF128 {
	vPrime := gfGad.Add(u, w)                          // u ^ v
	uPrime := gfGad.Add(u, gfGad.Mul(vPrime, t))       // u ^ (v' * t)
	return gfGad.Add(uPrime, gfGad.Mul(r, gfGad.Add(vPrime, uPrime))) // u' ^ r*(v'^u')
}

// computeTwiddle computes _twiddle(layer, pairIndex) in-circuit.
//
//	pairIndex = (chunkIndex << chunkShift) | indexOffset
//	          = variable bits (chunkBits) ++ constant bits (indexOffset)
//
// gnark's api.Xor is SINGLE-BIT only. We therefore maintain the 128-bit
// twiddle result as a bit array [128]frontend.Variable.
//
//   - Constant contributions (from the fixed indexOffset) flip bits at compile
//     time — stored in a plain [128]int (no circuit constraints).
//   - Variable contributions (from chunkBits) use api.Xor(resultBit, cond)
//     where cond is the chunkBit variable, adding 1 constraint per set bit.
//
// Constraint cost: ≤ 128 × numChunkBits api.Xor calls per twiddle.
// For 10 variable bits and sparse basis elements: ~300 constraints per twiddle.
func (v *Verifier) computeTwiddle(layer int, chunkBits []frontend.Variable, chunkShift, indexOffset, numChunkBits int) gf128.GF128 {
	// Constant accumulator (no circuit constraints).
	var constBits [128]int

	// Variable accumulator: starts as all 0 (constant), updated by api.Xor.
	varBits := make([]frontend.Variable, 128)
	for i := range varBits {
		varBits[i] = frontend.Variable(0)
	}

	// ── Constant contribution from indexOffset bits ───────────────────────
	for i := 0; i < chunkShift && i < layer; i++ {
		if (indexOffset>>i)&1 == 1 {
			blo, bhi := twiddleBasis(layer, i)
			xorConstBasis128(constBits[:], blo, bhi)
		}
	}

	// ── Variable contribution from chunkIndex bits ────────────────────────
	for j := 0; j < numChunkBits; j++ {
		basisIdx := chunkShift + j
		if basisIdx >= layer {
			break
		}
		blo, bhi := twiddleBasis(layer, basisIdx)
		cond := chunkBits[j]
		xorVarBasis128(v.api, varBits, blo, bhi, cond)
	}

	// ── Merge constant and variable parts ────────────────────────────────
	// result[i] = constBits[i] XOR varBits[i]
	// If constBits[i] == 0: result = varBits[i]   (no constraint)
	// If constBits[i] == 1: result = NOT varBits[i] = api.Xor(1, varBits[i])
	resultBits := make([]frontend.Variable, 128)
	for i := range resultBits {
		if constBits[i] == 0 {
			resultBits[i] = varBits[i]
		} else {
			// XOR a constant 1 into the boolean: flips the bit.
			resultBits[i] = v.api.Xor(frontend.Variable(1), varBits[i])
		}
	}

	return packBits128(v, resultBits)
}

// xorConstBasis128 XORs a 128-bit basis value (blo, bhi) into a [128]int bit
// array.  Operates purely at compile time — no circuit constraints.
func xorConstBasis128(bits []int, blo, bhi uint64) {
	for b := 0; b < 8; b++ {
		loByte := uint8(blo >> (8 * uint(b)))
		hiByte := uint8(bhi >> (8 * uint(b)))
		for k := 0; k < 8; k++ {
			bits[b*8+k] ^= int((loByte >> k) & 1)
			bits[(b+8)*8+k] ^= int((hiByte >> k) & 1)
		}
	}
}

// xorVarBasis128 conditionally XORs a 128-bit basis value (blo, bhi) into
// varBits based on condition bit `cond` (a circuit variable in {0,1}).
// For each set bit in the basis, adds one api.Xor constraint.
func xorVarBasis128(api frontend.API, varBits []frontend.Variable, blo, bhi uint64, cond frontend.Variable) {
	for b := 0; b < 8; b++ {
		loByte := uint8(blo >> (8 * uint(b)))
		hiByte := uint8(bhi >> (8 * uint(b)))
		for k := 0; k < 8; k++ {
			if (loByte>>k)&1 == 1 {
				varBits[b*8+k] = api.Xor(varBits[b*8+k], cond)
			}
			if (hiByte>>k)&1 == 1 {
				varBits[(b+8)*8+k] = api.Xor(varBits[(b+8)*8+k], cond)
			}
		}
	}
}

// packBits128 packs a 128-bit LSB-first bit array into a GF128.
// bits[0] = bit 0 (LSB of Lo limb), bits[63] = bit 63 (MSB of Lo limb),
// bits[64] = bit 64 (LSB of Hi limb), etc.
func packBits128(v *Verifier, bits []frontend.Variable) gf128.GF128 {
	loArr := make([]uints.U8, 8)
	hiArr := make([]uints.U8, 8)
	for b := 0; b < 8; b++ {
		// Pack 8 bits into one U8, LSB first (bit[0] = least significant).
		loArr[b] = uints.U8{Val: v.api.FromBinary(bits[b*8 : b*8+8]...)}
		hiArr[b] = uints.U8{Val: v.api.FromBinary(bits[64+b*8 : 64+b*8+8]...)}
	}
	return gf128.GF128{
		Lo: v.uapi.PackLSB(loArr...),
		Hi: v.uapi.PackLSB(hiArr...),
	}
}

// VerifyQuery verifies one FRI query:
//  1. Serialise the coset (bswap128 byte order) and hash it.
//  2. Verify the Merkle path against the commitment root.
//  3. Fold the coset using pre-sampled fold challenges.
//  4. Assert the folded value equals the claimed evaluation.
//
// foldChallenges MUST be sampled once per proof (from the per-proof transcript)
// before any VerifyQuery call — not inside VerifyQuery itself.
func (v *Verifier) VerifyQuery(
	traceRoot [32]uints.U8,
	witness QueryWitness,
	claim gf128.GF128,
	foldChallenges [NumFoldChallenges]gf128.GF128,
	logLen int,
) error {
	// Step 1: hash the coset.
	cosetBytes := cosetToBytes(v, witness.CosetValues)
	leafHash, err := compress.HashLeaf(v.api, cosetBytes)
	if err != nil {
		return err
	}

	// Step 2: authenticate against the commitment root.
	if err := merkle.Verify(v.api, leafHash, traceRoot, witness.AuthPath); err != nil {
		return err
	}

	// Step 3: fold and check.
	folded := v.FoldChunk(witness.CosetValues, foldChallenges, witness.ChunkIndex, logLen)
	v.gfGad.AssertEqual(folded, claim)

	return nil
}

// VerifyMiMCQuery verifies one FRI query using MiMC-BN254 for leaf hashing and
// Merkle path authentication.  The fold logic is identical to VerifyQuery;
// only the commitment opening verification uses MiMC.
//
// Protocol note: requires the binius64 Rust prover and on-chain verifier to
// also use MiMC for the Merkle tree.  This is the production-recommended path.
//
// Constraint cost per query (depth=20):
//   - HashLeafMiMC:    ~5,440 constraints
//   - VerifyField path: ~6,800 constraints
//   - FoldChunk:       ~23,000 constraints
//   - Total:           ~35,240 constraints  (SHA256 path: ~673,000)
func (v *Verifier) VerifyMiMCQuery(
	traceRoot frontend.Variable, // MiMC Merkle root (field element, not 32 bytes)
	witness MiMCQueryWitness,
	claim gf128.GF128,
	foldChallenges [NumFoldChallenges]gf128.GF128,
	logLen int,
) error {
	// Step 1: hash the coset using MiMC.
	leafHash, err := circuithash.HashLeafMiMC(v.api, v.uapi, witness.CosetValues)
	if err != nil {
		return err
	}

	// Step 2: authenticate against the commitment root using MiMC Merkle.
	if err := merkle.VerifyField(v.api, leafHash, traceRoot, witness.AuthPath); err != nil {
		return err
	}

	// Step 3: fold and check (identical to VerifyQuery).
	folded := v.FoldChunk(witness.CosetValues, foldChallenges, witness.ChunkIndex, logLen)
	v.gfGad.AssertEqual(folded, claim)

	return nil
}

// cosetToBytes serialises 16 GF128 elements into 256 bytes using the bswap128
// convention from FRIFold.sol / BaseFold._hashCoset:
//
//	Each 16-byte GF128 element stored LE as [lo_bytes, hi_bytes] is byte-reversed
//	to [hi_bytes_BE, lo_bytes_BE]:
//	  bytes [0..7]  = Hi limb in big-endian  (MSB first)
//	  bytes [8..15] = Lo limb in big-endian  (MSB first)
func cosetToBytes(v *Verifier, vals [CosetSize]gf128.GF128) [256]uints.U8 {
	var out [256]uints.U8
	for i, val := range vals {
		// UnpackMSB gives bytes in big-endian order (most-significant first).
		hiBytes := v.uapi.UnpackMSB(val.Hi) // [7..0] bytes of Hi MSB-first
		loBytes := v.uapi.UnpackMSB(val.Lo) // [7..0] bytes of Lo MSB-first
		base := i * 16
		for j := 0; j < 8; j++ {
			out[base+j] = hiBytes[j]   // Hi MSB → byte 0
			out[base+8+j] = loBytes[j] // Lo MSB → byte 8
		}
	}
	return out
}

// FoldInterleaved folds an interleaved coset using eq_ind tensor challenges,
// matching FRIFold.foldInterleaved in Solidity.
// Used to reduce from the trace oracle (GF128 values) to a single GF128 scalar.
func FoldInterleaved(
	gfGad *gf128.Gadget,
	values [CosetSize]gf128.GF128,
	challenges [NumFoldChallenges]gf128.GF128,
) gf128.GF128 {
	// Build eq_ind tensor via doubling.
	tensor := make([]gf128.GF128, CosetSize)
	tensor[0] = gf128.NewGF128Constant(1, 0)
	size := 1
	for k := 0; k < NumFoldChallenges; k++ {
		r := challenges[k]
		oneMinusR := gfGad.Add(gf128.NewGF128Constant(1, 0), r)
		for i := 0; i < size; i++ {
			base := tensor[i]
			tensor[i] = gfGad.Mul(base, oneMinusR)
			tensor[size+i] = gfGad.Mul(base, r)
		}
		size <<= 1
	}
	result := gf128.NewGF128Constant(0, 0)
	for i := 0; i < CosetSize; i++ {
		result = gfGad.Add(result, gfGad.Mul(values[i], tensor[i]))
	}
	return result
}

// ─────────────────────────────────────────────────────────────────────────────
// Twiddle basis table (layers 10–13, from FRIFold._twiddleBasis in Solidity)
//
// Each value is a 128-bit GF128 element split into (lo uint64, hi uint64).
// Generated by the two-level NTT construction:
//   initial_ntt = GenericOnTheFly(BinarySubspace::with_dim(18))
//   rs_subspace  = initial_ntt.subspace(14)
//   verifier_ntt = GenericOnTheFly(rs_subspace)
// ─────────────────────────────────────────────────────────────────────────────

// twiddleBasis returns the (lo, hi) uint64 pair for basis element (layer, idx).
// Panics at compile time if the (layer, idx) combination is out of range.
func twiddleBasis(layer, idx int) (lo, hi uint64) {
	switch layer {
	case 13:
		switch idx {
		case 0:
			return 0x0000000000010116, 0x0000000000000000
		case 1:
			return 0x000000010117177c, 0x0000000000000000
		case 2:
			return 0x00010117166b6bb8, 0x0000000000000000
		case 3:
			return 0x0117166a7cd2c270, 0x0000000000000001
		case 4:
			return 0x166a7dc5a8a5d0e0, 0x0000000000010117
		case 5:
			return 0x7dc4bfcf044af1c0, 0x000000010117166a
		case 6:
			return 0xbed86e9e4c90a380, 0x00010117166a7dc4
		case 7:
			return 0x79f4982c89344787, 0x0117166a7dc4bed9
		case 8:
			return 0xf2f8350952bb02e5, 0x166a7dc4bed978e3
		case 9:
			return 0xe1b56ed429c74a16, 0x7dc4bed978e2e592
		case 10:
			return 0xd2e8514d193bab5c, 0xbed978e2e4858b61
		case 11:
			return 0x6d34e97f1824248f, 0x78e2e4849c0b0654
		case 12:
			return 0x9098fded16fafbae, 0xe4849d1c6c80d108
		}
	case 12:
		switch idx {
		case 0:
			return 0x0000000100010116, 0x0000000000000000
		case 1:
			return 0x000101170117177c, 0x0000000000000001
		case 2:
			return 0x0116166b166b6bb8, 0x0000000100010117
		case 3:
			return 0x177c7dd27cd2c2f7, 0x000101170116166a
		case 4:
			return 0x6ab8bf32a8225c05, 0x0116166a177d7cc5
		case 5:
			return 0xd5e6e3ca8823a7d6, 0x177d7cc46bafa958
		case 6:
			return 0x36fbc943965cb7dc, 0x6baea84fc38c9e0e
		case 7:
			return 0xefa82fc44c2939ea, 0xc29b88644b3f779a
		case 8:
			return 0xbed10c8052bd89d9, 0x5d550a5e51715727
		case 9:
			return 0xb308e72211e9528c, 0x2cb5e9fec633e912
		case 10:
			return 0xc30103d784c6c9a6, 0x78ea91f0578d6c43
		case 11:
			return 0xe9f220e407f9295f, 0x2f6f88c75f0a0583
		}
	case 11:
		switch idx {
		case 0:
			return 0x0000000100010116, 0x0000000000000001
		case 1:
			return 0x00010117011717fb, 0x0000000100010117
		case 2:
			return 0x011616ec16ece75d, 0x00010116011616ec
		case 3:
			return 0x17fbf1b0f0bbd473, 0x011717fb17faf137
		case 4:
			return 0xe656255832be1000, 0x16ede7dae7c6a8b6
		case 5:
			return 0xc394b9bddc26a7d4, 0xf12b599c5911b953
		case 6:
			return 0x74878bba91f430e5, 0xa83a11f21faa39a0
		case 7:
			return 0xaa06a315c763458a, 0xb61c03dedacb4728
		case 8:
			return 0xb284e8f5336ec801, 0xf753a94b961212f5
		case 9:
			return 0xde661c1bfa9e54c7, 0x9e31010bf55d216a
		case 10:
			return 0x0116811ee0c59ab0, 0xa68c8debad1338c8
		}
	case 10:
		switch idx {
		case 0:
			return 0x0000000100010191, 0x0000000000000001
		case 1:
			return 0x000101900190db8c, 0x0000000100010190
		case 2:
			return 0x0191da1cda7323f9, 0x000101910191da1c
		case 3:
			return 0xdbe3f98bce73c31c, 0x0190db8cdbe2f963
		case 4:
			return 0x14010c0c6004d754, 0xda7223111516f770
		case 5:
			return 0xaf159ba8fe531ff5, 0xcf643861b90ac509
		case 6:
			return 0xb3229d9f43c2a615, 0x761a880ab5fce64b
		case 7:
			return 0x22a5bc68ed7d20c7, 0xf91dbeb12d4ed103
		case 8:
			return 0x0d22e9990f8d77ae, 0x96dcc8caf392a46d
		case 9:
			return 0x6cfe4c531287e075, 0x10431e06e6f26aef
		}
	}
	panic("fri.twiddleBasis: unsupported (layer, idx)")
}

// Verify that the transcript type is used (import guard).
var _ *transcript.State
