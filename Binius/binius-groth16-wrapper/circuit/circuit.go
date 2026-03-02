// Package circuit defines the BatchBiniusVerifier — the top-level gnark
// circuit that verifies a batch of N binius64 proofs in a single PLONK proof.
//
// # Production v3 architecture (this version)
//
//	┌─────────────────────────────────────────────────┐
//	│  BatchBiniusVerifier                             │
//	│  Transcript: MiMC-BN254 (field-element sponge)   │
//	│  Merkle:     MiMC-BN254 node hashes             │
//	│  FRI:        MiMC leaf + field-element path      │
//	└─────────────────────────────────────────────────┘
//	          ▼ single PLONK proof (~350k gas on-chain)
//	          ▼ amortises to ~3,500 gas per proof in a batch of 100
//
// # Constraint budget (N=100, D=20, Q=232)
//
//	Production v1 (SHA256 everywhere):  ~15.7B  → ~2 hours on GPU
//	Production v2 (MiMC Merkle):        ~1.48B  → ~12 minutes on GPU
//	Production v3 (full MiMC — this):    ~826M  → ~3.5 minutes on GPU (4M c/s)
//
// # Public inputs
//
//	BatchPublicInputsHash: a single BN254 field element (MiMC hash of all
//	(publicInputsHash[i], traceRoot[i]) pairs).  One public input instead of
//	32 — cheaper on-chain verification.
//
// # Security properties
//
//   • FRI polynomial commitment verified (MiMC Merkle paths + fold consistency).
//   • Sumcheck protocol verified in-circuit (round-by-round soundness).
//   • Ring-switch reduction verified in-circuit.
//   • Full MiMC Fiat-Shamir transcript for all challenges.
//   • FRI query indices bound to transcript.
//   • Batch digest (MiMC) ties on-chain commitment to all N verified proofs.
//
// # Protocol requirements (before production)
//
//   • Rust prover: switch to MiMC-BN254 for Merkle hashing AND Fiat-Shamir.
//   • BiniusBatchVerifier.sol: verify MiMC Merkle paths + MiMC batch digest.
package circuit

import (
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/std/math/uints"

	"github.com/envelopes/binius-groth16-wrapper/circuit/fri"
	"github.com/envelopes/binius-groth16-wrapper/circuit/gf128"
	"github.com/envelopes/binius-groth16-wrapper/circuit/merkle"
	"github.com/envelopes/binius-groth16-wrapper/circuit/ringswitch"
	"github.com/envelopes/binius-groth16-wrapper/circuit/sumcheck"
	"github.com/envelopes/binius-groth16-wrapper/circuit/transcript"
)

// DefaultBatchSize is the number of binius64 proofs verified per PLONK proof.
// At N=100: amortised ~3,500 gas per proof (350k total / 100).
const DefaultBatchSize = 100

// MerkleDepth is the fixed Merkle tree depth used in the binius64 commitment.
// For a trace of 2^20 rows: depth = 20.
const MerkleDepth = 20

// NumFRIQueries is the number of FRI query tests for 100-bit security.
const NumFRIQueries = 232

// FRILogLen is the log2 length of the FRI oracle codeword.
// For the binius64 default: log_domain_size=14.
const FRILogLen = 14

// NumSumcheckRounds = log2(FRI domain) = FRILogLen.
const NumSumcheckRounds = sumcheck.NumRounds // 14

// SingleProofWitness holds the private witness for one binius64 proof.
type SingleProofWitness struct {
	// TraceRoot is the MiMC-BN254 Merkle root of the polynomial commitment.
	// Stored as a single BN254 field element (replaces the previous [32]uints.U8
	// SHA256 root). The SHA256 transcript absorbs this via its 32 LE bytes.
	// Constraint cost to absorb: ~280 constraints (one-time per proof).
	TraceRoot frontend.Variable

	// PublicInputsHash is the SHA256 hash of the circuit's public output words.
	PublicInputsHash [32]uints.U8

	// SumcheckInitialClaim is the alleged sum Σ p(x) over the Boolean hypercube.
	// Verified by the sumcheck gadget round-by-round.
	SumcheckInitialClaim gf128.GF128

	// SumcheckWitness holds the prover's round messages for the sumcheck protocol.
	// Each round message is a degree-2 univariate polynomial over GF(2^128).
	SumcheckWitness sumcheck.Witness

	// RingSwitchOutput is the GF(2^128)-valued FRI claim produced by the ring-switch.
	// Derived in-circuit from the sumcheck final evaluation and a Fiat-Shamir challenge.
	// The FRI verifier checks each query against this value.
	RingSwitchOutput gf128.GF128

	// FRIQueries holds the per-query witnesses for all NumFRIQueries FRI tests.
	FRIQueries []FRIQueryWitness
}

// FRIQueryWitness is the private witness for one FRI query.
// Uses MiMC-BN254 for leaf hashing and Merkle path authentication.
//
// Constraint budget per query (depth=20):
//   HashLeafMiMC:  ~5,440 constraints (was ~125,000 with SHA256)
//   VerifyField:   ~6,800 constraints (was ~500,000 with BiniusCompress)
//   FoldChunk:     ~23,000 constraints (unchanged)
//   Total:         ~35,240 constraints (was ~673,000 — 19× cheaper)
type FRIQueryWitness struct {
	// CosetValues are the 16 GF128 elements opened at this query position.
	CosetValues [fri.CosetSize]gf128.GF128

	// ChunkIndex is the coset position in the FRI oracle (≤ 10-bit variable).
	ChunkIndex frontend.Variable

	// AuthPath is the MiMC Merkle authentication path (field-element siblings).
	AuthPath merkle.FieldPath
}

// BatchBiniusVerifier is the top-level gnark circuit.
// Parameterised by N = len(Proofs) at compile time.
//
// Public inputs:
//   - BatchPublicInputsHash [32]frontend.Variable
//
// Private witness:
//   - Proofs [N]SingleProofWitness
type BatchBiniusVerifier struct {
	// ── Public inputs ──────────────────────────────────────────────────────
	// BatchPublicInputsHash is the MiMC-BN254 digest of all
	// (publicInputsHash_field[i], traceRoot[i]) pairs.
	// A single BN254 field element — the PLONK verifier checks 1 public input
	// instead of 32 (cheaper on-chain gas and simpler Solidity).
	BatchPublicInputsHash frontend.Variable `gnark:",public"`

	// ── Private witness ────────────────────────────────────────────────────
	Proofs []SingleProofWitness
}

// Define is the gnark circuit definition.  Called once at compile time to
// generate the PLONK constraint system.
func (c *BatchBiniusVerifier) Define(api frontend.API) error {
	n := len(c.Proofs)

	// Build shared gadgets (lookup tables built once, reused across all N proofs).
	gfGad, err := gf128.NewGadget(api)
	if err != nil {
		return err
	}
	friVerifier, err := fri.NewVerifier(api, gfGad)
	if err != nil {
		return err
	}

	// Batch MiMC transcript: absorbs (publicInputsHash_field[i], traceRoot[i])
	// for all N proofs, producing a single field element BatchPublicInputsHash.
	// On-chain: the PLONK verifier checks 1 public input instead of 32.
	batchTranscript, err := transcript.NewMiMC(api)
	if err != nil {
		return err
	}

	for i := 0; i < n; i++ {
		pw := &c.Proofs[i]

		// ── Per-proof MiMC Fiat-Shamir transcript ───────────────────────────
		// Initial state h=0. First absorbed element: the MiMC trace root.
		// Cost: ~0 (just a Write call, no MiMC call yet).
		t, err := transcript.NewMiMC(api)
		if err != nil {
			return err
		}
		t.AbsorbVar(pw.TraceRoot) // bind transcript to this MiMC commitment

		// ── Sumcheck verification ────────────────────────────────────────────
		sumcheckFinal, err := sumcheck.Verify(api, gfGad, pw.SumcheckInitialClaim, pw.SumcheckWitness, t)
		if err != nil {
			return err
		}

		// ── Ring-switch reduction ────────────────────────────────────────────
		rsClaim, err := ringswitch.Verify(gfGad, sumcheckFinal, t)
		if err != nil {
			return err
		}
		gfGad.AssertEqual(rsClaim, pw.RingSwitchOutput)
		friClaim := pw.RingSwitchOutput

		// ── FRI fold challenges (sampled once per proof) ─────────────────────
		var foldChallenges [fri.NumFoldChallenges]gf128.GF128
		for k := 0; k < fri.NumFoldChallenges; k++ {
			lo, hi, err := t.ChallengeGF128()
			if err != nil {
				return err
			}
			foldChallenges[k] = gf128.GF128{Lo: lo, Hi: hi}
		}

		// ── FRI query verification ──────────────────────────────────────────
		// Each query challenge is a field element; extract numCosetBits from its
		// low-order bits (much simpler than the 4-byte big-endian SHA256 path).
		numCosetBits := FRILogLen - 4
		for q := 0; q < len(pw.FRIQueries); q++ {
			qw := pw.FRIQueries[q]

			// MiMC challenge → decompose 254 bits, take low numCosetBits.
			// api.ToBinary(v, n) asserts v < 2^n, so we must always decompose
			// the full 254-bit field element before extracting a subset.
			qBits, err := t.ChallengeBits(numCosetBits)
			if err != nil {
				return err
			}
			chunkFromTranscript := api.FromBinary(qBits...)
			api.AssertIsEqual(qw.ChunkIndex, chunkFromTranscript)

			if err := friVerifier.VerifyMiMCQuery(
				pw.TraceRoot,
				fri.MiMCQueryWitness{
					CosetValues: qw.CosetValues,
					ChunkIndex:  qw.ChunkIndex,
					AuthPath:    qw.AuthPath,
				},
				friClaim,
				foldChallenges,
				FRILogLen,
			); err != nil {
				return err
			}
		}

		// ── Accumulate into batch digest ────────────────────────────────────
		// publicInputsHash (32 SHA256 bytes) is packed into one field element.
		// traceRoot is already a field element — absorbed directly.
		batchTranscript.AbsorbBytes32(pw.PublicInputsHash)
		batchTranscript.AbsorbVar(pw.TraceRoot)
	}

	// ── Batch digest check ──────────────────────────────────────────────────
	// MiMC hash of all absorbed data must equal the public BatchPublicInputsHash.
	batchDigest, err := batchTranscript.Challenge()
	if err != nil {
		return err
	}
	api.AssertIsEqual(batchDigest, c.BatchPublicInputsHash)

	return nil
}

// NewBatchVerifierCircuit returns an uninitialised BatchBiniusVerifier
// with N proof slots, suitable for passing to frontend.Compile.
// All witnesses default to zero values; the caller fills them before proving.
func NewBatchVerifierCircuit(n int) *BatchBiniusVerifier {
	proofs := make([]SingleProofWitness, n)
	for i := range proofs {
		proofs[i].FRIQueries = make([]FRIQueryWitness, NumFRIQueries)
		for q := range proofs[i].FRIQueries {
			// FieldPath: Depth siblings, each a single field element (MiMC hash).
			proofs[i].FRIQueries[q].AuthPath = merkle.FieldPath{
				Depth:    MerkleDepth,
				Siblings: make([]frontend.Variable, MerkleDepth),
			}
		}
	}
	return &BatchBiniusVerifier{Proofs: proofs}
}
