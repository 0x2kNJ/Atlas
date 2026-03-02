// Package aggregator implements the off-chain aggregator service that:
//
//  1. Accepts binius64 proofs from users (100ms per proof, generated on-device).
//  2. Collects them into batches of N proofs (default N=100, ~3 minutes).
//  3. Runs the PLONK prover to produce a single batch proof.
//  4. Posts the batch proof on-chain to BiniusBatchVerifier.sol (~350k gas).
//
// Gas economics:
//
//	binius64 native verifier (per proof, L2):  ~540,000,000 gas  — NOT viable
//	PLONK batch proof (per tx):                   ~350,000 gas
//	Amortised per proof in batch of 100:            ~3,500 gas  ✓
//
// Latency model:
//
//	User submits proof at T=0ms     → gets aggregator signed receipt (soft finality)
//	Batch fills at T≈180,000ms      → PLONK proving starts (~3-5 min on server)
//	On-chain at T≈360,000ms         → hard finality (visible in contract storage)
//
// Only settlement and spend operations require on-chain finality.
// Liquidations and other time-critical ops use a separate fast path without ZK.
package aggregator

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"time"

	"github.com/consensys/gnark-crypto/ecc/bn254/fr"
	mimcbn254 "github.com/consensys/gnark-crypto/ecc/bn254/fr/mimc"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/std/math/uints"

	binius "github.com/envelopes/binius-groth16-wrapper/circuit"
	"github.com/envelopes/binius-groth16-wrapper/circuit/fri"
	"github.com/envelopes/binius-groth16-wrapper/circuit/gf128"
	"github.com/envelopes/binius-groth16-wrapper/circuit/merkle"
	"github.com/envelopes/binius-groth16-wrapper/circuit/sumcheck"
)

// BatchMeta is the metadata written alongside each batch proof.
type BatchMeta struct {
	BatchID       string    `json:"batch_id"`
	ProofCount    int       `json:"proof_count"`
	Timestamp     time.Time `json:"timestamp"`
	ProvingTimeMs int64     `json:"proving_time_ms"`

	// PublicInputsHashes[i] is the SHA256 hash of the i-th proof's public words.
	PublicInputsHashes []string `json:"public_inputs_hashes"`

	// TraceRoots[i] is the polynomial commitment root for the i-th proof.
	TraceRoots []string `json:"trace_roots"`

	// BatchPublicInputsHash is the MiMC-BN254 hash of all (packed(publicInputsHash[i]), traceRoot[i]).
	// A single BN254 field element (hex-encoded 32 bytes).
	// BiniusBatchVerifier.sol must use MiMC to reconstruct this from calldata.
	BatchPublicInputsHash string `json:"batch_public_inputs_hash"`
}

// RawSumcheckRound is one round message in the binius64 sumcheck protocol.
// It holds the three GF(2^128) polynomial coefficients for the degree-2
// univariate polynomial sent by the prover in this round.
type RawSumcheckRound struct {
	// Coeffs[k] is a 16-byte GF(2^128) element in little-endian order.
	Coeffs [sumcheck.CoeffPerRound][16]byte `json:"coeffs"`
}

// RawBinius64Proof is the serialised output of the Rust binius64 prover.
// See binius-verifier/src/Binius64NativeVerifier.sol for the proof format.
type RawBinius64Proof struct {
	// TraceRoot is the 32-byte polynomial commitment (Merkle root).
	TraceRoot [32]byte `json:"trace_root"`

	// PublicInputsHash is SHA256 of the public input words.
	PublicInputsHash [32]byte `json:"public_inputs_hash"`

	// SumcheckInitialClaim is the GF128 initial sum claim (16 bytes, LE).
	SumcheckInitialClaim [16]byte `json:"sumcheck_initial_claim"`

	// SumcheckRounds holds the NumSumcheckRounds round messages.
	SumcheckRounds [sumcheck.NumRounds]RawSumcheckRound `json:"sumcheck_rounds"`

	// RingSwitchOutput is the GF128 FRI claim after ring-switch reduction (16 bytes, LE).
	RingSwitchOutput [16]byte `json:"ring_switch_output"`

	// FRIQueries holds the per-query witnesses.
	FRIQueries []RawFRIQuery `json:"fri_queries"`
}

// RawFRIQuery is one FRI query's raw witness data.
// Uses MiMC-BN254 for Merkle hashing; each sibling is a 32-byte little-endian
// BN254 field element (not a SHA256 hash).
type RawFRIQuery struct {
	// CosetValues: 16 × 16 = 256 bytes (GF128 elements, LE).
	CosetValues [fri.CosetSize][16]byte `json:"coset_values"`

	// MerkleSiblings: depth × 32 bytes.
	// Each sibling is the 32-byte little-endian encoding of a BN254 field
	// element (MiMC-BN254 node hash), NOT a SHA256 digest.
	MerkleSiblings [][32]byte `json:"merkle_siblings"`

	// ChunkIndex is the coset position in the FRI oracle.
	ChunkIndex uint64 `json:"chunk_index"`
}

// BuildWitness reads N binius64 proof files from proofsDir and constructs
// a BatchBiniusVerifier circuit assignment ready for PLONK witness generation.
//
// Expected files: proof_0.json, proof_1.json, ..., proof_{N-1}.json
func BuildWitness(proofsDir string, n int) (*binius.BatchBiniusVerifier, *BatchMeta, error) {
	assignment := binius.NewBatchVerifierCircuit(n)
	meta := &BatchMeta{
		BatchID:            fmt.Sprintf("batch-%d", time.Now().Unix()),
		ProofCount:         n,
		Timestamp:          time.Now(),
		PublicInputsHashes: make([]string, n),
		TraceRoots:         make([]string, n),
	}

	// Accumulate public data for the MiMC batch digest.
	// The circuit uses MiMC-BN254 (Production v3): absorbs packed(publicInputsHash)
	// then traceRoot for each proof; the final Challenge() is the batch digest.
	batchHasher := mimcbn254.NewMiMC()

	for i := 0; i < n; i++ {
		proofPath := filepath.Join(proofsDir, fmt.Sprintf("proof_%d.json", i))
		raw, err := loadProof(proofPath)
		if err != nil {
			return nil, nil, fmt.Errorf("proof %d: %w", i, err)
		}

		if err := assignProof(assignment, i, raw); err != nil {
			return nil, nil, fmt.Errorf("assign proof %d: %w", i, err)
		}

		meta.PublicInputsHashes[i] = fmt.Sprintf("0x%x", raw.PublicInputsHash)
		meta.TraceRoots[i] = fmt.Sprintf("0x%x", raw.TraceRoot)

		// AbsorbBytes32(publicInputsHash): pack 32 SHA256 bytes as a field element.
		// gnark-crypto's MiMC silently drops elements >= field modulus; the circuit
		// auto-reduces via field arithmetic.  Reduce via fr.Element.SetBytes to match.
		pihBE := new(big.Int).SetBytes(raw.PublicInputsHash[:])
		var pihElem fr.Element
		pihElem.SetBytes(be32Pad(pihBE))
		pihBytes := pihElem.Bytes()
		batchHasher.Write(pihBytes[:])
		// AbsorbVar(traceRoot): traceRoot stored as LE, convert to BE for gnark-crypto.
		traceRootBE := le32ToBEBytes(raw.TraceRoot)
		batchHasher.Write(traceRootBE[:])
	}

	// Challenge() = Sum() + Write(result); we only need Sum() for the final value.
	batchDigestBytes := batchHasher.Sum(nil)
	batchDigestBigInt := new(big.Int).SetBytes(batchDigestBytes)
	meta.BatchPublicInputsHash = fmt.Sprintf("0x%x", batchDigestBytes)

	assignment.BatchPublicInputsHash = batchDigestBigInt

	return assignment, meta, nil
}

// loadProof reads and deserialises one binius64 proof from disk.
func loadProof(path string) (*RawBinius64Proof, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var proof RawBinius64Proof
	if err := json.Unmarshal(data, &proof); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	return &proof, nil
}

// le32ToBigInt converts a 32-byte little-endian BN254 field element (as stored
// in the JSON) to a *big.Int for use as a gnark frontend.Variable.
func le32ToBigInt(b [32]byte) *big.Int {
	var be [32]byte
	for j := 0; j < 32; j++ {
		be[31-j] = b[j]
	}
	return new(big.Int).SetBytes(be[:])
}

// le32ToBEBytes converts a 32-byte little-endian field element to big-endian.
func le32ToBEBytes(b [32]byte) [32]byte {
	var be [32]byte
	for j := 0; j < 32; j++ {
		be[31-j] = b[j]
	}
	return be
}

// be32Pad returns v as a 32-byte big-endian slice (zero-padded on the left).
func be32Pad(v *big.Int) []byte {
	b := v.Bytes()
	if len(b) == 32 {
		return b
	}
	padded := make([]byte, 32)
	copy(padded[32-len(b):], b)
	return padded
}

// assignProof converts a RawBinius64Proof into the circuit assignment at
// position i.
func assignProof(c *binius.BatchBiniusVerifier, i int, raw *RawBinius64Proof) error {
	pw := &c.Proofs[i]

	// Assign TraceRoot: 32 LE bytes of the MiMC-BN254 Merkle root → *big.Int.
	pw.TraceRoot = le32ToBigInt(raw.TraceRoot)

	// Assign PublicInputsHash (32 bytes, SHA256).
	for j := 0; j < 32; j++ {
		pw.PublicInputsHash[j] = uints.NewU8(raw.PublicInputsHash[j])
	}

	// Assign SumcheckInitialClaim (16 bytes LE → GF128).
	scLo := binary.LittleEndian.Uint64(raw.SumcheckInitialClaim[:8])
	scHi := binary.LittleEndian.Uint64(raw.SumcheckInitialClaim[8:])
	pw.SumcheckInitialClaim = gf128.NewGF128Constant(scLo, scHi)

	// Assign SumcheckWitness round messages.
	for r, rr := range raw.SumcheckRounds {
		for k, coeff := range rr.Coeffs {
			cLo := binary.LittleEndian.Uint64(coeff[:8])
			cHi := binary.LittleEndian.Uint64(coeff[8:])
			pw.SumcheckWitness.Rounds[r].Coeffs[k] = gf128.NewGF128Constant(cLo, cHi)
		}
	}

	// Assign RingSwitchOutput (16 bytes LE → GF128).
	rsLo := binary.LittleEndian.Uint64(raw.RingSwitchOutput[:8])
	rsHi := binary.LittleEndian.Uint64(raw.RingSwitchOutput[8:])
	pw.RingSwitchOutput = gf128.NewGF128Constant(rsLo, rsHi)

	// Assign FRI queries.
	if len(raw.FRIQueries) != binius.NumFRIQueries {
		return fmt.Errorf("expected %d FRI queries, got %d", binius.NumFRIQueries, len(raw.FRIQueries))
	}
	for q, rq := range raw.FRIQueries {
		qw := &pw.FRIQueries[q]

		// Coset values (16 × GF128, each 16 bytes LE).
		for k, cv := range rq.CosetValues {
			cvLo := binary.LittleEndian.Uint64(cv[:8])
			cvHi := binary.LittleEndian.Uint64(cv[8:])
			qw.CosetValues[k] = gf128.NewGF128Constant(cvLo, cvHi)
		}

		qw.ChunkIndex = rq.ChunkIndex

		// MiMC Merkle authentication path.
		// Each sibling is a 32-byte LE BN254 field element → *big.Int.
		// gnark's frontend.Variable is interface{}, so *big.Int is accepted directly.
		siblings := make([]frontend.Variable, len(rq.MerkleSiblings))
		for k, sib := range rq.MerkleSiblings {
			siblings[k] = le32ToBigInt(sib)
		}
		qw.AuthPath = merkle.FieldPath{
			Depth:    len(rq.MerkleSiblings),
			Siblings: siblings,
			Index:    rq.ChunkIndex,
		}
	}

	return nil
}

// ComputeBatchPublicInputsHash computes the MiMC-BN254 batch digest.
// Matches the in-circuit batchTranscript: for each proof, absorbs
// packed(publicInputsHash) (32 SHA256 bytes as a field element) then the
// MiMC traceRoot (field element).  Returns the first Sum() as a big.Int.
//
// The on-chain BiniusBatchVerifier.sol must use MiMC-BN254 to reconstruct.
func ComputeBatchPublicInputsHash(proofs []RawBinius64Proof) *big.Int {
	h := mimcbn254.NewMiMC()
	for _, p := range proofs {
		// Reduce mod field prime before writing (MiMC silently drops >= p).
		var pihElem fr.Element
		pihElem.SetBytes(be32Pad(new(big.Int).SetBytes(p.PublicInputsHash[:])))
		pihBytes := pihElem.Bytes()
		h.Write(pihBytes[:])
		traceRootBE := le32ToBEBytes(p.TraceRoot)
		h.Write(traceRootBE[:])
	}
	return new(big.Int).SetBytes(h.Sum(nil))
}
