// Package compress implements the BiniusCompress gadget for use inside a gnark circuit.
//
// BiniusCompress mirrors the Solidity BiniusCompress.sol: it runs the SHA256
// compression function (one 64-round block) with a binius-specific domain-
// separated IV instead of the standard SHA256 IV.  This is used for all
// internal Merkle tree nodes in the binius polynomial commitment scheme.
//
// The IV is derived as:
//
//	SHA256("binius-v0.1.0/merkle-tree/\x00")
//	= 0xd5e6c2d7... (computed offline, hardcoded as constants below)
//
// The standard SHA256 IV is defined in FIPS 180-4; we replace it with the
// binius domain-separated value to match the Rust prover.
package compress

import (
	"github.com/consensys/gnark/frontend"
	sha2gadget "github.com/consensys/gnark/std/hash/sha2"
	"github.com/consensys/gnark/std/math/uints"
	sha2perm "github.com/consensys/gnark/std/permutation/sha2"
)

// BiniusIV is the binius domain-separated SHA256 initial value.
//
// Derivation (verified against BiniusCompress.sol):
//
//   raw = SHA256("BINIUS SHA-256 COMPRESS")
//       = f54f6816d217a753c854411d561b4f574e527ea341fd2df132f903638c015437
//
//   IV[i] = LittleEndian.Uint32(raw[4*i : 4*i+4])
//
// This matches bytemuck::cast::<[u8;32],[u32;8]>(raw) on a little-endian
// (x86/ARM) machine, which is exactly what the Rust binius64 prover does.
//
// All 8 words verified against BiniusCompress.sol lines 73-80.
var BiniusIV = [8]uint32{
	0x16684ff5, // LE(raw[ 0: 4]) — f5 4f 68 16
	0x53a717d2, // LE(raw[ 4: 8]) — d2 17 a7 53
	0x1d4154c8, // LE(raw[ 8:12]) — c8 54 41 1d
	0x574f1b56, // LE(raw[12:16]) — 56 1b 4f 57
	0xa37e524e, // LE(raw[16:20]) — 4e 52 7e a3
	0xf12dfd41, // LE(raw[20:24]) — 41 fd 2d f1
	0x6303f932, // LE(raw[24:28]) — 32 f9 03 63
	0x3754018c, // LE(raw[28:32]) — 8c 01 54 37
}

// Compress computes BiniusCompress(left, right) in-circuit.
//
//   - left  is the 32-byte left  child hash (as 32 uints.U8 in big-endian byte order)
//   - right is the 32-byte right child hash
//
// Returns the 32-byte parent hash.
//
// Constraint cost: equivalent to one SHA256 block ≈ 25,000 PLONK constraints
// (dominated by the 64-round SHA256 permutation).
func Compress(
	api frontend.API,
	left, right [32]uints.U8,
) ([32]uints.U8, error) {
	uapi, err := uints.New[uints.U32](api)
	if err != nil {
		return [32]uints.U8{}, err
	}

	// Build the 64-byte block: left ++ right.
	var block [64]uints.U8
	for i := 0; i < 32; i++ {
		block[i] = left[i]
		block[32+i] = right[i]
	}

	// Initialise state from the binius domain-separated IV.
	var iv [8]uints.U32
	for i, word := range BiniusIV {
		iv[i] = uints.NewU32(word)
	}

	// Run one SHA256 compression block.
	newState := sha2perm.Permute(uapi, iv, block)

	// Serialise the 8×U32 output state into 32 bytes in LITTLE-ENDIAN word order.
	//
	// Binius uses bytemuck::cast::<[u32;8],[u8;32]> on x86 (little-endian), so
	// the first byte of each output word is its LEAST significant byte.
	// This reverses the byte order within each 32-bit word compared to the
	// standard SHA256 BE serialisation.  The Solidity BiniusCompress.sol does
	// the same with mstore8(outPtr+0, and(a, 0xff)), mstore8(outPtr+1, shr(8,a))…
	var out [32]uints.U8
	for i, word := range newState {
		wordBytes := uapi.UnpackLSB(word) // [4]U8, least-significant byte first
		out[4*i+0] = wordBytes[0]         // byte 0 = low  byte of word
		out[4*i+1] = wordBytes[1]
		out[4*i+2] = wordBytes[2]
		out[4*i+3] = wordBytes[3]         // byte 3 = high byte of word
	}
	return out, nil
}

// HashLeaf computes SHA256(coset_values) where coset_values is 256 bytes
// (16 GF128 elements, each 16 bytes, serialised in bswap128 order).
// This matches the SHA256 precompile call in Solidity BaseFold._hashCoset.
//
// Uses gnark's sha2.New for correct Merkle-Damgård padding, so the output
// matches crypto/sha256.Sum256(cosetBytes[:]) in Go exactly.
//
// Constraint cost: 5 SHA256 blocks ≈ 125,000 PLONK constraints.
func HashLeaf(
	api frontend.API,
	cosetBytes [256]uints.U8,
) ([32]uints.U8, error) {
	h, err := sha2gadget.New(api)
	if err != nil {
		return [32]uints.U8{}, err
	}
	h.Write(cosetBytes[:])
	digest := h.Sum() // 32 bytes, standard SHA256 big-endian output

	var out [32]uints.U8
	copy(out[:], digest)
	return out, nil
}

// stateToBytesLE serialises an [8]U32 SHA256 state into 32 bytes in
// little-endian word order (binius format: low byte of each word first).
func stateToBytesLE(uapi *uints.BinaryField[uints.U32], state [8]uints.U32) [32]uints.U8 {
	var out [32]uints.U8
	for i, word := range state {
		wordBytes := uapi.UnpackLSB(word) // LSB first = little-endian
		out[4*i+0] = wordBytes[0]
		out[4*i+1] = wordBytes[1]
		out[4*i+2] = wordBytes[2]
		out[4*i+3] = wordBytes[3]
	}
	return out
}

// stateToBytesBE serialises an [8]U32 SHA256 state into 32 bytes in standard
// big-endian word order (used for leaf hashes via the SHA256 precompile).
func stateToBytesBE(uapi *uints.BinaryField[uints.U32], state [8]uints.U32) [32]uints.U8 {
	var out [32]uints.U8
	for i, word := range state {
		wordBytes := uapi.UnpackMSB(word)
		out[4*i+0] = wordBytes[0]
		out[4*i+1] = wordBytes[1]
		out[4*i+2] = wordBytes[2]
		out[4*i+3] = wordBytes[3]
	}
	return out
}

// BytesFromVar converts a circuit frontend.Variable that is constrained to
// be in range [0, 255] into a uints.U8.
func BytesFromVar(api frontend.API, v frontend.Variable) uints.U8 {
	_ = api
	return uints.U8{Val: v}
}
