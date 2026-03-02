// Package merkle implements binary Merkle tree verification inside a gnark circuit.
//
// Two implementations are provided:
//
//  1. SHA256-based (Verify + Path): matches the original binius64 prover commitment
//     scheme exactly, using BiniusCompress for internal nodes. ~500k constraints
//     per depth-20 path due to SHA256 cost.
//
//  2. MiMC-based (VerifyField + FieldPath): uses MiMC-BN254 for all internal
//     nodes. ~6,800 constraints per depth-20 path (74× cheaper). Requires a
//     coordinated protocol change: the binius64 Rust prover and the on-chain
//     BiniusBatchVerifier.sol must also use MiMC for the Merkle tree.
//     This is the recommended path for production.
package merkle

import (
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/std/hash/mimc"
	"github.com/consensys/gnark/std/math/uints"

	"github.com/envelopes/binius-groth16-wrapper/circuit/compress"
)

// MaxDepth is the maximum Merkle tree depth supported (matches binius64 usage).
const MaxDepth = 32

// Path holds one Merkle authentication path of fixed length depth.
// Sibling[i] is the sibling hash at depth i (0 = leaf level).
// Index bit i determines which side (0 = left, 1 = right) the prover's node is on.
type Path struct {
	Depth    int
	Siblings [][32]uints.U8 // length = Depth
	Index    frontend.Variable
}

// Verify constrains that leaf hashes up the Merkle path to root.
//
//   - leaf: the 32-byte leaf hash (already computed by caller via HashLeaf)
//   - root: the expected 32-byte Merkle root (public input)
//   - path: authentication path
//
// The index bits select left/right at each level, using gnark's select to
// avoid branching.  The internal hash function is BiniusCompress.
func Verify(
	api frontend.API,
	leaf [32]uints.U8,
	root [32]uints.U8,
	path Path,
) error {
	uapi, err := uints.New[uints.U32](api)
	if err != nil {
		return err
	}

	// Depth=0 means no inner nodes — leaf IS the root; nothing to traverse.
	if path.Depth == 0 {
		assertBytes32Equal(api, uapi, leaf, root)
		return nil
	}

	// Decompose index into bits for path selection.
	indexBits := api.ToBinary(path.Index, path.Depth)

	current := leaf

	for level := 0; level < path.Depth; level++ {
		sibling := path.Siblings[level]
		bit := indexBits[level]

		// If bit == 0: current is left child, sibling is right child.
		// If bit == 1: sibling is left child, current is right child.
		left, right := selectBytes(api, uapi, bit, sibling, current)

		var err error
		current, err = compress.Compress(api, left, right)
		if err != nil {
			return err
		}
	}

	// Assert computed root == expected root.
	assertBytes32Equal(api, uapi, current, root)
	return nil
}

// selectBytes returns (a, b) if sel==0, else (b, a).
// Used to order left/right children based on the index bit.
func selectBytes(
	api frontend.API,
	uapi *uints.BinaryField[uints.U32],
	sel frontend.Variable,
	a, b [32]uints.U8,
) ([32]uints.U8, [32]uints.U8) {
	var left, right [32]uints.U8
	for i := 0; i < 32; i++ {
		// sel==0 → left=a[i], right=b[i]
		// sel==1 → left=b[i], right=a[i]
		left[i] = uints.U8{Val: api.Select(sel, b[i].Val, a[i].Val)}
		right[i] = uints.U8{Val: api.Select(sel, a[i].Val, b[i].Val)}
	}
	_ = uapi
	return left, right
}

// assertBytes32Equal constrains that two 32-byte arrays are equal.
func assertBytes32Equal(
	api frontend.API,
	uapi *uints.BinaryField[uints.U32],
	a, b [32]uints.U8,
) {
	for i := 0; i < 32; i++ {
		uapi.ByteAssertEq(a[i], b[i])
	}
	_ = api
}

// ─────────────────────────────────────────────────────────────────────────────
// MiMC-based Merkle tree (production path)
// ─────────────────────────────────────────────────────────────────────────────

// FieldPath is a Merkle authentication path where every node hash is a single
// BN254 field element (output of MiMC-BN254).  Replaces the byte-level Path
// when the protocol uses MiMC instead of SHA256/BiniusCompress for the tree.
//
// Constraint savings vs. Path:
//   - Each internal node: MiMC(left, right) ≈ 340 constraints
//     vs. BiniusCompress ≈ 25,000 constraints → 74× cheaper per level.
//   - Depth-20 path: ~6,800 constraints vs. ~500,000 constraints.
type FieldPath struct {
	Depth    int
	Siblings []frontend.Variable // one field element per level
	Index    frontend.Variable
}

// VerifyField verifies a MiMC-based Merkle authentication path in-circuit.
//
//   - leafHash: MiMC hash of the coset (output of hash.HashLeafMiMC)
//   - root:     expected Merkle root as a field element (public input / witness)
//   - path:     authentication siblings as field elements
//
// Constraint cost: depth × ~340 ≈ 6,800 constraints for depth=20.
func VerifyField(
	api frontend.API,
	leafHash frontend.Variable,
	root frontend.Variable,
	path FieldPath,
) error {
	if path.Depth == 0 {
		api.AssertIsEqual(leafHash, root)
		return nil
	}

	indexBits := api.ToBinary(path.Index, path.Depth)
	current := leafHash

	for level := 0; level < path.Depth; level++ {
		sib := path.Siblings[level]
		bit := indexBits[level]

		// bit==0 → current is left child, sib is right child.
		// bit==1 → sib is left child, current is right child.
		left := api.Select(bit, sib, current)
		right := api.Select(bit, current, sib)

		h, err := mimc.NewMiMC(api)
		if err != nil {
			return err
		}
		h.Write(left, right)
		current = h.Sum()
	}

	api.AssertIsEqual(current, root)
	return nil
}
