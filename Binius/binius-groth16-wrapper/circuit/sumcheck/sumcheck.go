// Package sumcheck implements in-circuit verification of the binius64 sumcheck
// protocol over GF(2^128).
//
// # Protocol overview
//
// The binius sumcheck proves that the sum of a multilinear polynomial p over the
// Boolean hypercube equals a claimed value:
//
//	Σ_{x ∈ {0,1}^n}  p(x)  =  initialClaim
//
// The verifier engages in n rounds.  In round i the prover sends a univariate
// polynomial p_i(X) of degree ≤ SumcheckPolyDegree and the verifier:
//
//  1. Checks   p_i(0) + p_i(1)  ==  current_claim  (equality in GF(2^128))
//  2. Absorbs the polynomial coefficients into the Fiat-Shamir transcript.
//  3. Samples a random challenge r_i from the transcript.
//  4. Updates current_claim  :=  p_i(r_i)  (Horner evaluation).
//
// After n rounds the circuit returns the final evaluation claim, which the
// ring-switch gadget then connects to the FRI oracle.
//
// # Parameters (binius64 defaults)
//
//	NumRounds  = 14   (log_2 of FRI domain length)
//	PolyDegree = 2    (degree of the round polynomial)
package sumcheck

import (
	"github.com/consensys/gnark/frontend"

	circuithash "github.com/envelopes/binius-groth16-wrapper/circuit/hash"
	"github.com/envelopes/binius-groth16-wrapper/circuit/gf128"
	"github.com/envelopes/binius-groth16-wrapper/circuit/transcript"
)

// NumRounds is the number of sumcheck rounds for binius64 (= FRILogLen = 14).
const NumRounds = 14

// PolyDegree is the maximum degree of the round univariate polynomials.
// Binius64 uses degree-2 polynomials (3 coefficients per round).
const PolyDegree = 2

// CoeffPerRound = PolyDegree + 1 = 3 coefficients per round polynomial.
const CoeffPerRound = PolyDegree + 1

// RoundWitness holds the prover's message for one sumcheck round:
// a univariate polynomial  p(X) = Coeffs[0] + Coeffs[1]*X + Coeffs[2]*X^2
// with coefficients in GF(2^128).
type RoundWitness struct {
	Coeffs [CoeffPerRound]gf128.GF128
}

// Witness groups all prover messages across the full sumcheck.
type Witness struct {
	Rounds [NumRounds]RoundWitness
}

// Verify verifies the sumcheck protocol in-circuit using the MiMC transcript.
//
//   - gfGad:        GF(2^128) arithmetic gadget (shared with the caller).
//   - initialClaim: the alleged sum Σ p(x) over the Boolean hypercube.
//   - w:            the prover's round messages.
//   - t:            MiMC Fiat-Shamir transcript.
//
// Returns the final evaluation claim p_{n-1}(r_{n-1}).
//
// Constraint cost per round (MiMC):
//   - 3 GF128 absorbs × 2 elements = 6 × ~0 (linear) = ~0
//   - ChallengeGF128: ~340 (MiMC) + 128 (ToBinary) ≈ 468
//   - GF128 add/mul: ~700
//   - Total: ~1,200 per round × 14 rounds = ~16,800 constraints
//   (SHA256 version: ~360,000 constraints — 21× more expensive)
func Verify(
	api frontend.API,
	gfGad *gf128.Gadget,
	initialClaim gf128.GF128,
	w Witness,
	t *transcript.MiMCState,
) (gf128.GF128, error) {
	uapi := gfGad.UApi()
	current := initialClaim

	for i := 0; i < NumRounds; i++ {
		round := w.Rounds[i]

		// ── Check: p_i(0) + p_i(1) = current claim ────────────────────────
		p0 := round.Coeffs[0]
		p1 := gfGad.Add(gfGad.Add(round.Coeffs[0], round.Coeffs[1]), round.Coeffs[2])
		sumAtEnds := gfGad.Add(p0, p1)
		gfGad.AssertEqual(sumAtEnds, current)

		// ── Absorb round polynomial into the MiMC transcript ──────────────
		// Each GF128 coefficient is absorbed as two field elements (lo, hi).
		// Constraint cost: ~0 (constant-coefficient linear reconstruction).
		for _, coeff := range round.Coeffs {
			lo := circuithash.U64ToFieldVar(api, uapi, coeff.Lo)
			hi := circuithash.U64ToFieldVar(api, uapi, coeff.Hi)
			t.AbsorbVars(lo, hi)
		}

		// ── Sample challenge r_i ───────────────────────────────────────────
		lo, hi, err := t.ChallengeGF128()
		if err != nil {
			return gf128.GF128{}, err
		}
		r := gf128.GF128{Lo: lo, Hi: hi}

		// ── Evaluate p_i at r via Horner: p(r) = C[0] + r*(C[1] + r*C[2]) ─
		inner := gfGad.Add(round.Coeffs[1], gfGad.Mul(r, round.Coeffs[2]))
		current = gfGad.Add(round.Coeffs[0], gfGad.Mul(r, inner))
	}

	return current, nil
}

// ── Compile-time helpers for test fixture generation ─────────────────────────

// GF128FromBytes deserialises 16 little-endian bytes into a pair of (lo, hi)
// uint64 values suitable for NewGF128Constant.  Used only in tests / offline.
func GF128FromBytes(b [16]byte) (lo, hi uint64) {
	for i := 0; i < 8; i++ {
		lo |= uint64(b[i]) << (8 * uint(i))
		hi |= uint64(b[8+i]) << (8 * uint(i))
	}
	return
}

// VerifyOff verifies the sumcheck protocol purely in Go (no circuit).
// Used to generate valid synthetic witnesses for testing.
// Returns the final evaluation claim.
//
// hashChallenge is a function that: (1) absorbs the given bytes, then
// (2) calls challenge() and returns the 32-byte digest used to derive a GF128.
func VerifyOff(
	initialClaim [16]byte,
	rounds [][CoeffPerRound][16]byte,
	hashChallenge func(toAbsorb [][16]byte) [32]byte,
) (finalClaim [16]byte, ok bool) {
	current := initialClaim

	for _, round := range rounds {
		// Check: p(0) + p(1) = current
		p0 := round[0]
		p1 := xorBytes16(xorBytes16(round[0], round[1]), round[2])
		sumAtEnds := xorBytes16(p0, p1)
		if sumAtEnds != current {
			return finalClaim, false
		}

		// Sample challenge.
		digest := hashChallenge(round[:])
		// ChallengeGF128: lo from digest[8..15] reversed, hi from digest[24..31] reversed
		var r [16]byte
		for i := 0; i < 8; i++ {
			r[i] = digest[15-i]
			r[8+i] = digest[31-i]
		}

		// Horner: p(r) = Coeffs[0] + r*(Coeffs[1] + r*Coeffs[2])
		inner := gf128AddOff(round[1], gf128MulOff(r, round[2]))
		current = gf128AddOff(round[0], gf128MulOff(r, inner))
	}
	return current, true
}

func xorBytes16(a, b [16]byte) (out [16]byte) {
	for i := range out {
		out[i] = a[i] ^ b[i]
	}
	return
}

// gf128AddOff adds two GF(2^128) elements in Go (XOR).
func gf128AddOff(a, b [16]byte) (out [16]byte) {
	return xorBytes16(a, b)
}

// gf128MulOff multiplies two GF(2^128) elements in Go using the binius tower.
// Only used for test fixture generation.
func gf128MulOff(a, b [16]byte) [16]byte {
	// Unpack to uint64 limbs.
	var aLo, aHi, bLo, bHi uint64
	for i := 0; i < 8; i++ {
		aLo |= uint64(a[i]) << (8 * uint(i))
		aHi |= uint64(a[8+i]) << (8 * uint(i))
		bLo |= uint64(b[i]) << (8 * uint(i))
		bHi |= uint64(b[8+i]) << (8 * uint(i))
	}
	// GF(2^128) = GF(2^64)[X]/(X^2+X+alpha) Karatsuba:
	// ll = aLo*bLo, hh = aHi*bHi, m = (aLo^aHi)*(bLo^bHi)
	ll := gf64MulOff(aLo, bLo)
	hh := gf64MulOff(aHi, bHi)
	mm := gf64MulOff(aLo^aHi, bLo^bHi)
	alphaHH := gf64MulAlphaOff(hh) // hh * alpha_GF128 = hh * [0,0,0,0,1,0,0,0]
	resLo := ll ^ alphaHH
	resHi := mm ^ ll
	var out [16]byte
	for i := 0; i < 8; i++ {
		out[i] = byte(resLo >> (8 * uint(i)))
		out[8+i] = byte(resHi >> (8 * uint(i)))
	}
	return out
}

// gf64MulOff multiplies two GF(2^64) elements in Go.
func gf64MulOff(a, b uint64) uint64 {
	// Karatsuba: GF(2^64) = GF(2^32)[Y]/(Y^2+Y+alpha) where alpha=[0,0,1,0]
	aLo, aHi := uint32(a), uint32(a>>32)
	bLo, bHi := uint32(b), uint32(b>>32)
	ll := gf32MulOff(aLo, bLo)
	hh := gf32MulOff(aHi, bHi)
	mm := gf32MulOff(aLo^aHi, bLo^bHi)
	alphaHH := gf32MulAlphaOff(hh)
	return uint64(ll^alphaHH) | (uint64(mm^ll) << 32)
}

func gf32MulOff(a, b uint32) uint32 {
	aLo, aHi := uint16(a), uint16(a>>16)
	bLo, bHi := uint16(b), uint16(b>>16)
	ll := gf16MulOffU16(aLo, bLo)
	hh := gf16MulOffU16(aHi, bHi)
	mm := gf16MulOffU16(aLo^aHi, bLo^bHi)
	alphaHH := gf16MulAlphaOff(hh)
	return uint32(ll^alphaHH) | (uint32(mm^ll) << 16)
}

// Compile-time tower constants for Go-side arithmetic.
func gf16MulOffU16(a, b uint16) uint16 {
	aLo, aHi := uint8(a), uint8(a>>8)
	bLo, bHi := uint8(b), uint8(b>>8)
	ll := gf8MulOff(aLo, bLo)
	hh := gf8MulOff(aHi, bHi)
	mm := gf8MulOff(aLo^aHi, bLo^bHi)
	alphaHH := gf8MulAlphaOff(hh) // hh * 16 in GF256
	return uint16(ll^alphaHH) | (uint16(mm^ll) << 8)
}

func gf8MulAlphaOff(a uint8) uint8 { return gf8MulOff(a, 16) }

func gf8MulOff(a, b uint8) uint8 {
	aLo, aHi := a&0xF, a>>4
	bLo, bHi := b&0xF, b>>4
	ll := gf4MulOff(aLo, bLo)
	hh := gf4MulOff(aHi, bHi)
	mm := gf4MulOff(aLo^aHi, bLo^bHi)
	return (ll ^ gf4MulAlphaOff(hh)) | ((mm ^ ll) << 4)
}

func gf4MulAlphaOff(a uint8) uint8 { return gf4MulOff(a, 2) }
func gf4MulOff(a, b uint8) uint8 {
	a0, a1 := a&1, (a>>1)&1
	b0, b1 := b&1, (b>>1)&1
	ll := a0 & b0
	hh := a1 & b1
	mm := (a0 ^ a1) & (b0 ^ b1)
	return (ll ^ hh) | (((mm ^ ll) & 1) << 1)
}

func gf16MulAlphaOff(a uint16) uint16 {
	// alpha_GF32 = [0,1] in GF(2^16)  →  [a,b] * [0,1] = [mul16(b,alpha_16), a^b]
	aLo, aHi := uint8(a), uint8(a>>8)
	r0 := gf8MulAlphaOff(aHi)
	r1 := aLo ^ aHi
	return uint16(r0) | (uint16(r1) << 8)
}

func gf32MulAlphaOff(a uint32) uint32 {
	// alpha_GF64 = [0,0,1,0] in GF(2^32)
	a0, a1, a2, a3 := uint8(a), uint8(a>>8), uint8(a>>16), uint8(a>>24)
	r0 := gf8MulAlphaOff(a3) // gf256Mul(a3, 16)
	r1 := a2 ^ a3
	r2 := a0 ^ a2
	r3 := a1 ^ a3
	return uint32(r0) | uint32(r1)<<8 | uint32(r2)<<16 | uint32(r3)<<24
}

func gf64MulAlphaOff(a uint64) uint64 {
	// alpha_GF128 = [0,0,0,0,1,0,0,0] in GF(2^64)
	b := [8]byte{}
	for i := range b {
		b[i] = byte(a >> (8 * uint(i)))
	}
	r0 := gf8MulAlphaOff(b[7]) // gf256Mul(a7,16)
	r1 := b[6] ^ b[7]
	r2 := b[4] ^ b[6]
	r3 := b[5] ^ b[7]
	r4 := b[0] ^ b[4]
	r5 := b[1] ^ b[5]
	r6 := b[2] ^ b[6]
	r7 := b[3] ^ b[7]
	return uint64(r0) | uint64(r1)<<8 | uint64(r2)<<16 | uint64(r3)<<24 |
		uint64(r4)<<32 | uint64(r5)<<40 | uint64(r6)<<48 | uint64(r7)<<56
}
