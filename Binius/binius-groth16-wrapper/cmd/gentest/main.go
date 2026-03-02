// cmd/gentest generates synthetic binius64 proof fixtures for end-to-end testing.
//
// It creates N proof_*.json files in an output directory, each containing a
// synthetically valid proof where all coset values are zero.  This lets you run
// the full cmd/setup → cmd/prove → cmd/export pipeline without a real Rust prover.
//
// Usage:
//
//	go run ./cmd/gentest \
//	  --batch-size 100 \
//	  --out-dir ./batch_proofs \
//	  --merkle-depth 20 \
//	  --fri-queries 232
//
// The generated proofs satisfy all binius wrapper circuit constraints because:
//   - All GF128 coset values = 0 → fold result = 0 for any challenges.
//   - LeafHash = MiMC-BN254(16 zero field elements) = known constant.
//   - Merkle siblings are MiMC node hashes (not SHA256 hashes).
//   - Sumcheck: all-zero coefficients, initial claim = 0 → always valid.
//   - ChunkIndex derived from Fiat-Shamir transcript (matching circuit order:
//     sumcheck → ring-switch → FRI fold challenges → query challenges).
package main

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"math/big"
	"os"
	"path/filepath"

	mimcbn254 "github.com/consensys/gnark-crypto/ecc/bn254/fr/mimc"

	"github.com/envelopes/binius-groth16-wrapper/aggregator"
	binius "github.com/envelopes/binius-groth16-wrapper/circuit"
	"github.com/envelopes/binius-groth16-wrapper/circuit/fri"
	sc "github.com/envelopes/binius-groth16-wrapper/circuit/sumcheck"
)

func main() {
	batchSize := flag.Int("batch-size", binius.DefaultBatchSize, "number of proof files to generate")
	outDir := flag.String("out-dir", "./batch_proofs", "output directory for proof_N.json files")
	merkleDepth := flag.Int("merkle-depth", binius.MerkleDepth, "Merkle tree depth")
	numFRIQueries := flag.Int("fri-queries", binius.NumFRIQueries, "number of FRI queries per proof")
	flag.Parse()

	if err := os.MkdirAll(*outDir, 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "mkdir %s: %v\n", *outDir, err)
		os.Exit(1)
	}

	fmt.Printf("Generating %d synthetic proof fixtures in %s ...\n", *batchSize, *outDir)

	for i := 0; i < *batchSize; i++ {
		proof := buildSyntheticProof(i, *merkleDepth, *numFRIQueries)
		path := filepath.Join(*outDir, fmt.Sprintf("proof_%d.json", i))
		data, err := json.MarshalIndent(proof, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "marshal proof %d: %v\n", i, err)
			os.Exit(1)
		}
		if err := os.WriteFile(path, data, 0o644); err != nil {
			fmt.Fprintf(os.Stderr, "write proof %d: %v\n", i, err)
			os.Exit(1)
		}
		if (i+1)%10 == 0 || i == *batchSize-1 {
			fmt.Printf("  %d/%d proofs written\n", i+1, *batchSize)
		}
	}

	fmt.Println()
	fmt.Printf("✓  Done. To prove:\n")
	fmt.Printf("   go run ./cmd/setup --batch-size %d\n", *batchSize)
	fmt.Printf("   go run ./cmd/prove --proofs-dir %s\n", *outDir)
}

// buildSyntheticProof constructs a proof_i that satisfies all circuit constraints.
// The proof index i is incorporated into the publicInputsHash so each proof is unique.
func buildSyntheticProof(proofIdx, merkleDepth, numFRIQueries int) *aggregator.RawBinius64Proof {
	// ── Deterministic per-proof seed ─────────────────────────────────────────
	seed := sha256.Sum256([]byte(fmt.Sprintf("envelopes-test-proof-%d", proofIdx)))

	// ── PublicInputsHash ─────────────────────────────────────────────────────
	var publicInputsHash [32]byte
	copy(publicInputsHash[:], seed[:])

	// ── Coset data: all zeros → fold result = zero for any FRI challenge ─────
	var zeroCosetVal [16]byte
	var cosetVals [fri.CosetSize][16]byte
	for k := range cosetVals {
		cosetVals[k] = zeroCosetVal
	}

	// ── MiMC leaf hash of 16 zero GF128 elements ─────────────────────────────
	// Each GF128(0,0) packs to 0 in BN254; the MiMC result is deterministic.
	leafHashLE := mimcHashLeaf(cosetVals)

	// ── MiMC Merkle tree: all siblings = running hash, index = 0 ─────────────
	// For index=0, the prover node is always the left child.
	// sibling[level] = right child = current node (degenerate: all identical).
	var traceRootLE [32]byte
	currentLE := leafHashLE
	siblings := make([][32]byte, merkleDepth)
	for level := 0; level < merkleDepth; level++ {
		siblings[level] = currentLE // sibling = same hash (degenerate tree)
		currentLE = mimcHashNodes(currentLE, siblings[level])
	}
	traceRootLE = currentLE

	// ── Fiat-Shamir transcript simulation (must match circuit.go Define order) ─
	// Order: init → absorb(traceRoot LE) → 14 sumcheck rounds → ring-switch
	//        → 4 FRI fold challenges → per-query challenge
	emptyHash := sha256.Sum256(nil)

	// Step 1+2: init buffer = emptyHash (32) || le32(traceRoot) (32) = 64 bytes.
	initBuf := append(emptyHash[:], traceRootLE[:]...)

	// Step 3: sumcheck — 14 rounds with all-zero coefficients.
	var zeroPoly [48]byte // 3 × 16-byte GF128 coefficients = 48 zero bytes
	cCur := sha256.Sum256(append(initBuf, zeroPoly[:]...))
	for round := 1; round < sc.NumRounds; round++ {
		cCur = sha256.Sum256(append(cCur[:], zeroPoly[:]...))
	}

	// Step 4: ring-switch — absorb 16 zero bytes (sumcheckFinal = 0).
	var zeroFinal [16]byte
	rs := sha256.Sum256(append(cCur[:], zeroFinal[:]...))

	// Step 5: 4 × FRI fold challenges (no data absorbed, just hash-chain).
	fc := rs
	for k := 0; k < fri.NumFoldChallenges; k++ {
		fc = sha256.Sum256(fc[:])
	}

	// Step 6: per-query challenges — one SHA256 per query.
	friQueries := make([]aggregator.RawFRIQuery, numFRIQueries)
	c := fc
	for q := 0; q < numFRIQueries; q++ {
		c = sha256.Sum256(c[:])
		rawIdx := (uint64(c[0]) << 24) | (uint64(c[1]) << 16) | (uint64(c[2]) << 8) | uint64(c[3])
		numCosetBits := binius.FRILogLen - 4 // 10
		cosetMask := uint64((1 << numCosetBits) - 1)
		chunkIdx := rawIdx & cosetMask

		// All Merkle siblings for this query (same degenerate tree).
		merkleSibs := make([][32]byte, merkleDepth)
		copy(merkleSibs, siblings)

		friQueries[q] = aggregator.RawFRIQuery{
			CosetValues:    cosetVals,
			MerkleSiblings: merkleSibs,
			ChunkIndex:     chunkIdx,
		}
	}

	return &aggregator.RawBinius64Proof{
		TraceRoot:            traceRootLE,
		PublicInputsHash:     publicInputsHash,
		SumcheckInitialClaim: [16]byte{},
		// SumcheckRounds: zero-value = all zero coefficients (valid for zero claim)
		RingSwitchOutput: [16]byte{},
		FRIQueries:       friQueries,
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// MiMC-BN254 helpers
// ─────────────────────────────────────────────────────────────────────────────

// shift64 = 2^64 for GF128 packing.
var shift64 = new(big.Int).Lsh(big.NewInt(1), 64)

// mimcHashLeaf computes MiMC-BN254 of 16 GF128 elements.
// Each GF128 element is packed as a single BN254 field element: lo + hi*2^64.
// Returns the 32-byte little-endian encoding of the field element result.
func mimcHashLeaf(vals [fri.CosetSize][16]byte) [32]byte {
	h := mimcbn254.NewMiMC()
	for _, v := range vals {
		lo := binary.LittleEndian.Uint64(v[:8])
		hi := binary.LittleEndian.Uint64(v[8:])
		packed := new(big.Int).SetUint64(lo)
		packed.Add(packed, new(big.Int).Mul(new(big.Int).SetUint64(hi), shift64))
		// gnark-crypto MiMC.Write expects big-endian 32-byte field element.
		var be [32]byte
		pb := packed.Bytes()
		copy(be[32-len(pb):], pb)
		h.Write(be[:])
	}
	return beToLE(h.Sum(nil))
}

// mimcHashNodes computes MiMC-BN254(left, right) for two Merkle node hashes.
// Both inputs and the output are 32-byte little-endian field elements.
func mimcHashNodes(left, right [32]byte) [32]byte {
	h := mimcbn254.NewMiMC()
	leftBE := leToBeArray(left)
	rightBE := leToBeArray(right)
	h.Write(leftBE[:])
	h.Write(rightBE[:])
	return beToLE(h.Sum(nil))
}

// leToBeArray reverses a [32]byte from LE to BE (for gnark-crypto input).
func leToBeArray(le [32]byte) [32]byte {
	var be [32]byte
	for j := 0; j < 32; j++ {
		be[31-j] = le[j]
	}
	return be
}

// beToLE reverses a byte slice from BE to LE and returns a [32]byte.
func beToLE(be []byte) [32]byte {
	var out [32]byte
	for j := 0; j < 32; j++ {
		out[j] = be[31-j]
	}
	return out
}
