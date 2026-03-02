// E2E integration test for BatchBiniusVerifier (Production v3 — full MiMC).
//
// Uses a small circuit configuration (batch=1, Merkle depth=0, FRI queries=1)
// and a synthetically constructed witness to verify the full
// compile → witness-generation → solve pipeline.
//
// # Synthetic witness construction (Production v3 / full MiMC)
//
//   - All coset values = 0  → fold result = 0 for any FRI challenge.
//   - All sumcheck round coefficients = 0  → claim stays 0.
//   - TraceRoot = MiMC-BN254(16 zero GF128 elements) = known constant.
//   - Merkle depth = 0  → circuit asserts leafHash == traceRoot; no siblings.
//   - ChunkIndex is derived from the MiMC Fiat-Shamir chain (computed below).
//   - BatchPublicInputsHash = MiMC(packed_publicInputsHash, traceRoot).
//
// # Pre-computed MiMC constants (gnark-crypto v0.14.0, BN254)
//
//	MiMC(16 zeros) BE hex:
//	  2369aa59f1f52216f305b9ad3b88be1479b25ff97b933be91329c803330966cd
//
//	chunk_index = 232  (from MiMC transcript chain below)
//
//	batch_digest = 16384071200422221386883662549812708058652216395562165919910135077304099524053
//	  (MiMC of packed(SHA256("envelopes-test-public-inputs-v1")), traceRoot)
//
// # Transcript chain (mirrors circuit.go Define exactly)
//
//	 1. AbsorbVar(traceRoot)
//	 2. 14 sumcheck rounds: Write(lo=0, hi=0) × 3 → ChallengeGF128()
//	 3. Ring-switch: Write(finalLo=0, finalHi=0) → ChallengeGF128()
//	 4. 4 × FRI fold challenges: ChallengeGF128() (no new absorb)
//	 5. 1 × query challenge: Challenge() → low 10 bits = chunkIndex
//	Batch: MiMC(packed(publicInputsHash), traceRoot) → batchDigest
package circuit_test

import (
	"crypto/sha256"
	"encoding/hex"
	"math/big"
	"testing"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/std/math/uints"
	"github.com/consensys/gnark/test"

	. "github.com/envelopes/binius-groth16-wrapper/circuit"
	"github.com/envelopes/binius-groth16-wrapper/circuit/fri"
	"github.com/envelopes/binius-groth16-wrapper/circuit/gf128"
	"github.com/envelopes/binius-groth16-wrapper/circuit/merkle"
)

// Pre-computed MiMC constants (verified via /tmp/mimc_test, gnark-crypto v0.14.0).
//
// IMPORTANT: gnark-crypto's MiMC Write() silently drops elements >= field modulus p.
// The circuit auto-reduces mod p via field arithmetic.  All Go-side simulations
// must therefore reduce inputs mod p before writing (use fr.Element.SetBytes).
//
// batch_digest = MiMC(sha256_packed_mod_p, traceRoot)
// where sha256_packed_mod_p = horner32(publicInputsHash) mod BN254_p
var (
	mimcLeafHashBE, _  = hex.DecodeString("2369aa59f1f52216f305b9ad3b88be1479b25ff97b933be91329c803330966cd")
	mimcLeafHashBigInt = new(big.Int).SetBytes(mimcLeafHashBE)
	mimcChunkIndex     = uint32(232)
	mimcBatchDigest, _ = new(big.Int).SetString(
		"5666023853065302228845118679348604865701492282018795041808189417216198040602", 10)
)

// TestE2ESolving verifies that a correctly constructed synthetic witness satisfies
// all circuit constraints (Production v3: full MiMC transcript + MiMC Merkle).
func TestE2ESolving(t *testing.T) {
	circuit := newSmallTestCircuit()
	assignment := newSmallTestAssignment(t)

	assert := test.NewAssert(t)
	assert.SolvingSucceeded(circuit, assignment, test.WithCurves(ecc.BN254))
}

// ─────────────────────────────────────────────────────────────────────────────
// Small test circuit: batch=1, depth=0, queries=1
// ─────────────────────────────────────────────────────────────────────────────

func newSmallTestCircuit() *BatchBiniusVerifier {
	proofs := make([]SingleProofWitness, 1)
	proofs[0].FRIQueries = make([]FRIQueryWitness, 1)
	proofs[0].FRIQueries[0].AuthPath = merkle.FieldPath{
		Depth:    0,
		Siblings: make([]frontend.Variable, 0),
	}
	return &BatchBiniusVerifier{Proofs: proofs}
}

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic witness (Production v3 values)
// ─────────────────────────────────────────────────────────────────────────────

func newSmallTestAssignment(t *testing.T) *BatchBiniusVerifier {
	t.Helper()

	var zeroCoset [fri.CosetSize]gf128.GF128
	publicInputsHash := sha256.Sum256([]byte("envelopes-test-public-inputs-v1"))

	proofs := make([]SingleProofWitness, 1)

	// TraceRoot: MiMC-BN254 of 16 zero GF128 elements (single field element).
	proofs[0].TraceRoot = mimcLeafHashBigInt

	// PublicInputsHash: SHA256 of the test string.
	proofs[0].PublicInputsHash = bytesToU8Array32(publicInputsHash)

	// Sumcheck: zero initial claim, all zero round coefficients (valid: 0+0=0).
	proofs[0].SumcheckInitialClaim = gf128.NewGF128Constant(0, 0)
	// SumcheckWitness: zero-value by default (all GF128 zero coefficients).

	// RingSwitchOutput: sumcheckFinal=0 → ring_switch_claim = 0 × ... = 0.
	proofs[0].RingSwitchOutput = gf128.NewGF128Constant(0, 0)

	// FRI query: coset values all zero, ChunkIndex from pre-computed transcript.
	// AuthPath: Depth=0 → VerifyField asserts leafHash == traceRoot directly.
	proofs[0].FRIQueries = make([]FRIQueryWitness, 1)
	proofs[0].FRIQueries[0] = FRIQueryWitness{
		CosetValues: zeroCoset,
		ChunkIndex:  frontend.Variable(mimcChunkIndex),
		AuthPath: merkle.FieldPath{
			Depth:    0,
			Siblings: make([]frontend.Variable, 0),
			Index:    frontend.Variable(0),
		},
	}

	// BatchPublicInputsHash: single BN254 field element (pre-computed MiMC value).
	return &BatchBiniusVerifier{
		BatchPublicInputsHash: mimcBatchDigest,
		Proofs:                proofs,
	}
}

func bytesToU8Array32(b [32]byte) [32]uints.U8 {
	var out [32]uints.U8
	for i, v := range b {
		out[i] = uints.NewU8(v)
	}
	return out
}
