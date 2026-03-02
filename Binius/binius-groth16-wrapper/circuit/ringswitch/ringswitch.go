// Package ringswitch implements the binius ring-switch reduction in-circuit.
//
// # What the ring switch does
//
// binius64 evaluates polynomials over GF(2^128) but the FRI oracle encodes
// evaluations over a packed field GF(2^64).  The ring-switch converts the
// GF(2^128) sumcheck final evaluation claim into the GF(2^128)-valued claim
// that FRI must match.
//
// For the binius64 one-level ring switch (GF(2^128) ↔ GF(2^64) packing):
//
//	f ∈ GF(2^128)[x_1,...,x_n]  (original polynomial)
//	g ∈ GF(2^128)[x_1,...,x_{n-1}]  (packed polynomial, 2 values per entry)
//
// Given the sumcheck final evaluation at point r = (r_1,...,r_n):
//
//	ring_switch_claim = (1 - r_n) * eval_lo  +  r_n * eval_hi
//
// where eval_lo and eval_hi are the two GF(2^64) halves of the sumcheck final
// evaluation unpacked into GF(2^128).
//
// In our GF(2^128) representation Lo = bits[0..63], Hi = bits[64..127]:
//
//	eval_lo = {Lo: sumcheckFinal.Lo, Hi: 0}   (lower 64 bits promoted to GF128)
//	eval_hi = {Lo: sumcheckFinal.Hi, Hi: 0}   (upper 64 bits promoted to GF128)
//	(1 - r_n) = 1 XOR r_n  (XOR in binary field = GF128 addition)
//
// The ring switch challenge r_n is sampled from the Fiat-Shamir transcript
// after absorbing the sumcheck final evaluation.
//
// NOTE: This implements the structural ring-switch formula.  The exact binius64
// polynomial packing convention should be verified against binius_core once the
// Rust prover source is available.
package ringswitch

import (
	"github.com/consensys/gnark/std/math/uints"

	circuithash "github.com/envelopes/binius-groth16-wrapper/circuit/hash"
	"github.com/envelopes/binius-groth16-wrapper/circuit/gf128"
	"github.com/envelopes/binius-groth16-wrapper/circuit/transcript"
)

// Verify computes the ring-switch reduction in-circuit using the MiMC transcript.
//
// Protocol:
//  1. Absorb sumcheckFinal as two field elements (lo, hi) into the transcript.
//  2. Sample ring-switch challenge r_n.
//  3. Compute: claim = (1 XOR r_n) * eval_lo  XOR  r_n * eval_hi
//
// Constraint cost: ~340 (MiMC absorb 2 elements + challenge) vs ~25,000 (SHA256).
func Verify(
	gfGad *gf128.Gadget,
	sumcheckFinal gf128.GF128,
	t *transcript.MiMCState,
) (gf128.GF128, error) {
	api := gfGad.API()
	uapi := gfGad.UApi()

	// Absorb sumcheckFinal as two field elements (lo, hi).
	finalLoVar := circuithash.U64ToFieldVar(api, uapi, sumcheckFinal.Lo)
	finalHiVar := circuithash.U64ToFieldVar(api, uapi, sumcheckFinal.Hi)
	t.AbsorbVars(finalLoVar, finalHiVar)

	// Sample the ring-switch challenge r_n ∈ GF(2^128).
	lo, hi, err := t.ChallengeGF128()
	if err != nil {
		return gf128.GF128{}, err
	}
	rn := gf128.GF128{Lo: lo, Hi: hi}

	// Promote Lo and Hi halves of the sumcheck final eval to full GF(2^128).
	// eval_lo = {Lo: final.Lo, Hi: 0}  (lower 64 bits of the evaluation)
	// eval_hi = {Lo: final.Hi, Hi: 0}  (upper 64 bits promoted)
	evalLo := gf128.GF128{Lo: sumcheckFinal.Lo, Hi: uints.NewU64(0)}
	evalHi := gf128.GF128{Lo: sumcheckFinal.Hi, Hi: uints.NewU64(0)}

	// (1 XOR r_n): in GF(2^128), 1 is {Lo: 1, Hi: 0}
	one := gf128.NewGF128Constant(1, 0)
	oneMinusRn := gfGad.Add(one, rn) // XOR in GF(2^128)

	// claim = (1 XOR r_n) * eval_lo  XOR  r_n * eval_hi
	termLo := gfGad.Mul(oneMinusRn, evalLo)
	termHi := gfGad.Mul(rn, evalHi)
	claim := gfGad.Add(termLo, termHi)

	return claim, nil
}

// VerifyOff is the Go-side implementation of the ring switch, used to generate
// synthetic test fixtures.  Returns the FRI claim for given inputs.
func VerifyOff(
	sumcheckFinal [16]byte,
	sampleChallenge func(toAbsorb [16]byte) [32]byte,
) [16]byte {
	digest := sampleChallenge(sumcheckFinal)

	// ChallengeGF128 byte layout (matches transcript.ChallengeGF128).
	var rn [16]byte
	for i := 0; i < 8; i++ {
		rn[i] = digest[15-i]
		rn[8+i] = digest[31-i]
	}

	// evalLo = {Lo: final.Lo, Hi: 0}; evalHi = {Lo: final.Hi, Hi: 0}
	var evalLo, evalHi [16]byte
	copy(evalLo[:8], sumcheckFinal[:8])
	copy(evalHi[:8], sumcheckFinal[8:])

	// (1 XOR r_n)
	var one [16]byte
	one[0] = 1
	oneMinusRn := xorBytes16Off(one, rn)

	// claim = (1^rn)*evalLo ^ rn*evalHi
	termLo := gf128MulOff(oneMinusRn, evalLo)
	termHi := gf128MulOff(rn, evalHi)
	return xorBytes16Off(termLo, termHi)
}

func xorBytes16Off(a, b [16]byte) (out [16]byte) {
	for i := range out {
		out[i] = a[i] ^ b[i]
	}
	return
}

// gf128MulOff: inline GF(2^128) multiply in Go for test fixture generation.
// (Duplicated from sumcheck to avoid circular imports; small enough to inline.)
func gf128MulOff(a, b [16]byte) [16]byte {
	var aLo, aHi, bLo, bHi uint64
	for i := 0; i < 8; i++ {
		aLo |= uint64(a[i]) << (8 * uint(i))
		aHi |= uint64(a[8+i]) << (8 * uint(i))
		bLo |= uint64(b[i]) << (8 * uint(i))
		bHi |= uint64(b[8+i]) << (8 * uint(i))
	}
	ll := gf64MulOff(aLo, bLo)
	hh := gf64MulOff(aHi, bHi)
	mm := gf64MulOff(aLo^aHi, bLo^bHi)
	alphaHH := gf64MulAlphaOff(hh)
	resLo := ll ^ alphaHH
	resHi := mm ^ ll
	var out [16]byte
	for i := 0; i < 8; i++ {
		out[i] = byte(resLo >> (8 * uint(i)))
		out[8+i] = byte(resHi >> (8 * uint(i)))
	}
	return out
}

func gf64MulOff(a, b uint64) uint64 {
	aLo, aHi := uint32(a), uint32(a>>32)
	bLo, bHi := uint32(b), uint32(b>>32)
	ll := gf32MulOff(aLo, bLo)
	hh := gf32MulOff(aHi, bHi)
	mm := gf32MulOff(aLo^aHi, bLo^bHi)
	return uint64(ll^gf32MulAlphaOff(hh)) | (uint64(mm^ll) << 32)
}

func gf32MulOff(a, b uint32) uint32 {
	aLo, aHi := uint16(a), uint16(a>>16)
	bLo, bHi := uint16(b), uint16(b>>16)
	ll := gf16MulOff(aLo, bLo)
	hh := gf16MulOff(aHi, bHi)
	mm := gf16MulOff(aLo^aHi, bLo^bHi)
	return uint32(ll^gf16MulAlphaOff(hh)) | (uint32(mm^ll) << 16)
}

func gf16MulOff(a, b uint16) uint16 {
	aLo, aHi := uint8(a), uint8(a>>8)
	bLo, bHi := uint8(b), uint8(b>>8)
	ll := gf8MulOff(aLo, bLo)
	hh := gf8MulOff(aHi, bHi)
	mm := gf8MulOff(aLo^aHi, bLo^bHi)
	return uint16(ll^gf8MulAlphaOff(hh)) | (uint16(mm^ll) << 8)
}

func gf8MulOff(a, b uint8) uint8 {
	aLo, aHi := a&0xF, a>>4
	bLo, bHi := b&0xF, b>>4
	ll := gf4MulOff(aLo, bLo)
	hh := gf4MulOff(aHi, bHi)
	mm := gf4MulOff(aLo^aHi, bLo^bHi)
	return (ll ^ gf4MulAlphaOff(hh)) | ((mm ^ ll) << 4)
}

func gf4MulOff(a, b uint8) uint8 {
	a0, a1 := a&1, (a>>1)&1
	b0, b1 := b&1, (b>>1)&1
	ll := a0 & b0
	hh := a1 & b1
	mm := (a0 ^ a1) & (b0 ^ b1)
	return (ll ^ hh) | (((mm ^ ll) & 1) << 1)
}

func gf4MulAlphaOff(a uint8) uint8  { return gf4MulOff(a, 2) }
func gf8MulAlphaOff(a uint8) uint8  { return gf8MulOff(a, 16) }
func gf16MulAlphaOff(a uint16) uint16 {
	aLo, aHi := uint8(a), uint8(a>>8)
	return uint16(gf8MulAlphaOff(aHi)) | (uint16(aLo^aHi) << 8)
}

func gf32MulAlphaOff(a uint32) uint32 {
	a0, a1, a2, a3 := uint8(a), uint8(a>>8), uint8(a>>16), uint8(a>>24)
	return uint32(gf8MulAlphaOff(a3)) | uint32(a2^a3)<<8 | uint32(a0^a2)<<16 | uint32(a1^a3)<<24
}

func gf64MulAlphaOff(a uint64) uint64 {
	b := [8]byte{}
	for i := range b {
		b[i] = byte(a >> (8 * uint(i)))
	}
	return uint64(gf8MulAlphaOff(b[7])) | uint64(b[6]^b[7])<<8 |
		uint64(b[4]^b[6])<<16 | uint64(b[5]^b[7])<<24 |
		uint64(b[0]^b[4])<<32 | uint64(b[1]^b[5])<<40 |
		uint64(b[2]^b[6])<<48 | uint64(b[3]^b[7])<<56
}
