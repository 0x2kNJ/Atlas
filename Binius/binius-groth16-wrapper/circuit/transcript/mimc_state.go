// MiMC-based Fiat-Shamir transcript for the binius64 gnark wrapper circuit.
//
// # Why switch from SHA256 to MiMC for the transcript
//
// The SHA256-based transcript (State) costs ~25,000–50,000 constraints per
// Challenge() call.  With 14 sumcheck rounds, 1 ring-switch, 4 fold challenges,
// and 232 query challenges per proof, that is ~6.3 million transcript constraints
// per proof — the dominant cost even after switching Merkle hashing to MiMC.
//
// MiMC-BN254 costs ~340 constraints per element absorbed.  The same transcript
// with MiMC costs ~85,000 constraints per proof — a 74× reduction.
//
// # Full MiMC circuit (Production v3)
//
// Component                 SHA256 cost     MiMC cost    Reduction
// Sumcheck (14 rounds)       700,000           4,760       147×
// Ring-switch                 25,000             340        74×
// FRI fold challenges (4)    100,000           1,360        74×
// Query challenges (232)   5,800,000          78,880        74×
// Transcript total         6,625,000          85,340        78×
// Merkle (per-query, ×232)   650M/proof        8.2M/proof   79×
// Total (N=100)              ~1.48B          ~826M          1.8×
//
// At 4M constraints/s on a server GPU:  826M / 4M ≈ 3.5 minutes for N=100.
// Compare Production v2 (MiMC Merkle + SHA256 transcript): ~12 minutes.
//
// # Protocol requirements
//
//   • BatchPublicInputsHash is now a single BN254 field element (not 32 bytes).
//     On-chain: the PLONK verifier checks 1 public input instead of 32.
//   • The binius64 Rust prover's Fiat-Shamir transcript switches to MiMC-BN254.
//     Challenge derivation: lo = bits[0..63] of MiMC output, hi = bits[64..127].
//   • BiniusBatchVerifier.sol computes the batch digest using MiMC, not SHA256.
//
// # State machine
//
// The MiMCState uses gnark's MiMC in Miyaguchi–Preneel streaming mode:
//
//	state h = 0  (initial)
//
//	Write(v₁, v₂, …):
//	  h = h + encrypt(h, v₁) + v₁
//	  h = h + encrypt(h, v₂) + v₂
//	  …
//	  data = nil  (flushed)
//
//	Challenge():
//	  result = h   (via h.Sum(), which flushes h.data)
//	  Write(result)  (feed result back to seed next round)
//	  return result
//
// This gives a collision-resistant, binding transcript where every challenge
// depends transitively on all prior absorb calls.
package transcript

import (
	"math/big"

	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/std/hash/mimc"
	"github.com/consensys/gnark/std/math/uints"
)

// MiMCState is the MiMC-BN254 based Fiat-Shamir transcript state.
// Replaces State (SHA256) for Production v3 circuits.
type MiMCState struct {
	api  frontend.API
	uapi *uints.BinaryField[uints.U64]
	h    mimc.MiMC
}

// NewMiMC creates a fresh MiMC transcript with h = 0.
func NewMiMC(api frontend.API) (*MiMCState, error) {
	uapi, err := uints.New[uints.U64](api)
	if err != nil {
		return nil, err
	}
	h, err := mimc.NewMiMC(api)
	if err != nil {
		return nil, err
	}
	return &MiMCState{api: api, uapi: uapi, h: h}, nil
}

// AbsorbVar absorbs a single BN254 field element into the transcript.
func (s *MiMCState) AbsorbVar(v frontend.Variable) {
	s.h.Write(v)
}

// AbsorbVars absorbs multiple field elements at once.
func (s *MiMCState) AbsorbVars(vs ...frontend.Variable) {
	s.h.Write(vs...)
}

// AbsorbBytes32 packs 32 circuit bytes (big-endian) into a single BN254 field
// element and absorbs it.  Used for SHA256-derived public values (PublicInputsHash).
//
// Packing: b[0]·256^31 + b[1]·256^30 + … + b[31].
// In PLONK this is a constant-coefficient linear combination: ~31 constraints.
func (s *MiMCState) AbsorbBytes32(b [32]uints.U8) {
	packed := bytes32ToFieldVar(s.api, b)
	s.h.Write(packed)
}

// Challenge flushes the current absorption buffer (calls MiMC Sum), feeds the
// result back as the seed for the next round, and returns the challenge.
//
// Constraint cost: (number of elements absorbed since last Challenge) × ~340.
// Subsequent calls with no new absorbs cost ~340 constraints each (one MiMC call
// on the single seed element written by the previous Challenge).
func (s *MiMCState) Challenge() (frontend.Variable, error) {
	result := s.h.Sum() // processes h.data → updates h.h → clears h.data
	s.h.Write(result)   // seed for the next round
	return result, nil
}

// ChallengeGF128 derives a GF(2^128) challenge from the MiMC transcript.
//
// The low 128 bits of the MiMC output field element are interpreted as a GF128
// element in little-endian order:
//
//	Lo = bits[ 0.. 63] of the field element  (low  64 bits)
//	Hi = bits[64..127] of the field element  (next 64 bits)
//
// IMPORTANT: api.ToBinary(v, n) asserts v < 2^n in the constraint system.
// MiMC output is a 254-bit field element, so we must decompose all 254 bits
// first, then extract the low 128.
//
// Constraint cost: ~340 (Challenge) + 254 (ToBinary) + ~16 (byte packing) ≈ 610.
func (s *MiMCState) ChallengeGF128() (lo, hi uints.U64, err error) {
	v, err := s.Challenge()
	if err != nil {
		return lo, hi, err
	}
	// Decompose the full 254-bit field element; take the low 128 bits.
	bits := s.api.ToBinary(v, 254)
	lo = fieldBitsToU64(s.api, s.uapi, bits[:64])
	hi = fieldBitsToU64(s.api, s.uapi, bits[64:128])
	return lo, hi, nil
}

// ChallengeBits decomposes the full 254-bit MiMC challenge and returns the
// first n bits (LSB-first).  n must be ≤ 254.
// Used by callers that need only a few index bits (e.g. FRI query chunk index).
func (s *MiMCState) ChallengeBits(n int) ([]frontend.Variable, error) {
	v, err := s.Challenge()
	if err != nil {
		return nil, err
	}
	bits := s.api.ToBinary(v, 254) // full decomposition
	return bits[:n], nil
}

// ─────────────────────────────────────────────────────────────────────────────
// Package-level helpers
// ─────────────────────────────────────────────────────────────────────────────

// bytes32ToFieldVar packs 32 bytes (big-endian) into a single field variable.
// Uses Horner's method to keep the constraint count minimal (~31 gates in PLONK).
func bytes32ToFieldVar(api frontend.API, b [32]uints.U8) frontend.Variable {
	result := b[0].Val
	for i := 1; i < 32; i++ {
		result = api.Add(api.Mul(result, big.NewInt(256)), b[i].Val)
	}
	return result
}

// fieldBitsToU64 converts 64 bits (LSB-first) into a uints.U64.
// The bits are grouped into 8 bytes (bits[i*8..(i+1)*8] = byte i, LSB-first),
// then packed via uapi.PackLSB.
func fieldBitsToU64(api frontend.API, uapi *uints.BinaryField[uints.U64], bits []frontend.Variable) uints.U64 {
	var bs [8]uints.U8
	for i := 0; i < 8; i++ {
		bs[i] = uints.U8{Val: api.FromBinary(bits[i*8 : (i+1)*8]...)}
	}
	return uapi.PackLSB(bs[:]...)
}
