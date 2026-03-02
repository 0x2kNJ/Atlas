// Package gf128 implements GF(2^128) arithmetic gadgets for use inside a gnark circuit.
//
// GF(2^128) is the canonical binary tower field used by binius64 for FRI fold
// and ring-switch arithmetic.  The tower is:
//
//   GF(2^2)   = GF(2)[x]   / (x^2 + x + 1)         alpha = 1  in GF(2)
//   GF(2^4)   = GF4[x]     / (x^2 + x + 2)          alpha = 2  in GF4
//   GF(2^8)   = GF16[x]    / (x^2 + x + 4)          alpha = 4  in GF16
//   GF(2^16)  = GF256[x]   / (x^2 + x + 16)         alpha = 16 in GF256
//   GF(2^32)  = GF(2^16)[x]/ (x^2 + x + [0,1])      alpha = [0x00,0x01]  in GF(2^16)
//   GF(2^64)  = GF(2^32)[x]/ (x^2 + x + [0,0,1,0])  alpha = [0,0,0x01,0] in GF(2^32)
//   GF(2^128) = GF(2^64)[x]/ (x^2 + x + [0,0,0,0,1,0,0,0]) alpha in GF(2^64)
//
// GF128 is stored as two uints.U64 limbs (Lo = bits 0-63, Hi = bits 64-127),
// in little-endian bit order (Lo[0] = constant term).
//
// All GF256 multiplications use a 65536-entry logderiv lookup table
// (~3 PLONK constraints per GF256 mul).  GF128 multiplication costs 81 such
// lookups ≈ 243 constraints.
package gf128

import (
	"fmt"

	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/std/lookup/logderivlookup"
	"github.com/consensys/gnark/std/math/uints"
)

// GF128 is a GF(2^128) element as two 64-bit limbs.
type GF128 struct {
	Lo uints.U64 // bits  0..63
	Hi uints.U64 // bits 64..127
}

// NewGF128Constant returns a compile-time-constant GF128 element.
func NewGF128Constant(lo, hi uint64) GF128 {
	return GF128{Lo: uints.NewU64(lo), Hi: uints.NewU64(hi)}
}

// Gadget holds prebuilt lookup tables shared across all GF128 operations.
// Create exactly one Gadget per circuit via NewGadget and reuse it everywhere.
type Gadget struct {
	api  frontend.API
	uapi *uints.BinaryField[uints.U64]

	// gf256MulTable: 65536-entry logderiv table.
	// Entry at index (a<<8 | b) = gf256MulConst(a, b).
	gf256MulTable *logderivlookup.Table

	// byteXorTable: 65536-entry logderiv table.
	// Entry at index (a<<8 | b) = a XOR b.
	// This is far cheaper than bit-decomposition (2-3 constraints vs ~24).
	byteXorTable *logderivlookup.Table

	// mulAlpha4: 256-entry table: x -> gf256MulConst(x, 16).
	// Used by every level of the tower (alpha for GF(2^16) over GF(2^8) = 16).
	mulAlpha4 *logderivlookup.Table
}

// NewGadget builds all lookup tables.  Call once during circuit compilation.
func NewGadget(api frontend.API) (*Gadget, error) {
	uapi, err := uints.New[uints.U64](api)
	if err != nil {
		return nil, err
	}
	g := &Gadget{api: api, uapi: uapi}

	// GF256 multiplication table (65536 entries).
	g.gf256MulTable = logderivlookup.New(api)
	for idx := 0; idx < 65536; idx++ {
		g.gf256MulTable.Insert(gf256MulConst(uint8(idx>>8), uint8(idx&0xFF)))
	}

	// Byte XOR lookup table (65536 entries).
	// Replaces bit-decomposition-based byte XOR (~24 constraints → ~2 constraints).
	g.byteXorTable = logderivlookup.New(api)
	for idx := 0; idx < 65536; idx++ {
		g.byteXorTable.Insert(uint64(uint8(idx>>8) ^ uint8(idx&0xFF)))
	}

	// mul-by-16 table for GF256 (256 entries).
	g.mulAlpha4 = logderivlookup.New(api)
	for x := 0; x < 256; x++ {
		g.mulAlpha4.Insert(gf256MulConst(uint8(x), 16))
	}
	return g, nil
}

// ── Public GF128 arithmetic ──────────────────────────────────────────────────

// Add computes a + b = a XOR b in GF(2^128).
func (g *Gadget) Add(a, b GF128) GF128 {
	return GF128{
		Lo: g.uapi.Xor(a.Lo, b.Lo),
		Hi: g.uapi.Xor(a.Hi, b.Hi),
	}
}

// Mul computes a * b in GF(2^128) via the 4-level Karatsuba binary tower
// starting at GF(2^8).  ~81 GF256 lookups ≈ 243 PLONK constraints.
func (g *Gadget) Mul(a, b GF128) GF128 {
	aBytes := append(g.uapi.UnpackLSB(a.Lo), g.uapi.UnpackLSB(a.Hi)...)
	bBytes := append(g.uapi.UnpackLSB(b.Lo), g.uapi.UnpackLSB(b.Hi)...)
	res := g.mulBytes(aBytes, bBytes) // 16-byte result
	return g.packBytes(res)
}

// MulConst multiplies a by a compile-time constant (cLo, cHi).
// Only valid when cHi == 0 (the constant fits in 64 bits).
// Panics at circuit-compile time if cHi != 0.
func (g *Gadget) MulConst(a GF128, cLo, cHi uint64) GF128 {
	if cHi != 0 {
		panic(fmt.Sprintf("gf128.MulConst: constant 0x%x_%x overflows 64 bits; cHi must be 0 for carry-free mul", cHi, cLo))
	}
	aBytes := append(g.uapi.UnpackLSB(a.Lo), g.uapi.UnpackLSB(a.Hi)...)
	cBytes := uint64ToBytes(cLo) // 8 bytes (cHi==0 guaranteed above)

	res := make([]frontend.Variable, 16)
	for i := range res {
		res[i] = frontend.Variable(0)
	}
	for i, cb := range cBytes {
		if cb == 0 {
			continue
		}
		for j, ab := range aBytes {
			pos := (i + j) % 16
			if (i+j)/16 != 0 {
				// Overflow requires full GF128 reduction — only valid when
				// cLo fits in 8 bytes (guaranteed above) so i < 8.
				// j < 16 → i+j < 24 → (i+j)/16 < 2.  When i+j >= 16 we'd
				// be reducing.  For cLo-only constants the maximum shift is
				// i=7, j=15 → i+j=22 → overflow=1. Signal an explicit panic
				// so callers know they hit a reduction case we don't handle.
				panic("gf128.MulConst: constant causes carry beyond byte 15; use Mul for general multiplication")
			}
		idx := g.api.Add(g.api.Mul(ab.Val, 256), cb)
		prod := g.gf256MulTable.Lookup(idx)[0]
		res[pos] = g.xorByte(res[pos], prod)
		}
	}
	return g.packBytes(res)
}

// AssertEqual constrains a == b by checking all 16 bytes.
// UApi exposes the underlying uints.BinaryField[uints.U64] so callers (e.g.
// transcript, sumcheck) can reconstruct U64 values from raw bits or vice versa
// without requiring an import cycle back to gf128.
func (g *Gadget) UApi() *uints.BinaryField[uints.U64] { return g.uapi }

// API exposes the underlying frontend.API.
func (g *Gadget) API() frontend.API { return g.api }

func (g *Gadget) AssertEqual(a, b GF128) {
	for i, ab := range g.uapi.UnpackLSB(a.Lo) {
		g.uapi.ByteAssertEq(ab, g.uapi.UnpackLSB(b.Lo)[i])
	}
	for i, ab := range g.uapi.UnpackLSB(a.Hi) {
		g.uapi.ByteAssertEq(ab, g.uapi.UnpackLSB(b.Hi)[i])
	}
}

// ── Internal tower multiplication ────────────────────────────────────────────

// mulBytes multiplies two GF(2^(8*n)) elements, each represented as n bytes
// (n must be a power of 2: 1, 2, 4, 8, or 16).
// At n==1 uses the GF256 lookup table (base case).
// At n>1 uses Karatsuba: res_lo = ll + alpha*hh, res_hi = m + ll.
func (g *Gadget) mulBytes(a, b []uints.U8) []frontend.Variable {
	n := len(a)
	if n == 1 {
		idx := g.api.Add(g.api.Mul(a[0].Val, 256), b[0].Val)
		return g.gf256MulTable.Lookup(idx)
	}

	half := n / 2
	aLo, aHi := a[:half], a[half:]
	bLo, bHi := b[:half], b[half:]

	ll := g.mulBytes(aLo, bLo)
	hh := g.mulBytes(aHi, bHi)
	m := g.mulBytes(g.xorByteSlices(aLo, aHi), g.xorByteSlices(bLo, bHi))

	alphaHH := g.mulByAlpha(hh, half)
	resLo := g.xorVars(ll, alphaHH)
	resHi := g.xorVars(m, ll)

	res := make([]frontend.Variable, n)
	copy(res[:half], resLo)
	copy(res[half:], resHi)
	return res
}

// mulByAlpha multiplies a GF(2^(8*halfSize)) element hh by the binius tower
// alpha constant, dispatching on halfSize (1, 2, 4, or 8).
//
// Derivations of the alpha multiplication formulas are commented inline and
// are verified against the binius canonical tower definition.
func (g *Gadget) mulByAlpha(hh []frontend.Variable, halfSize int) []frontend.Variable {
	switch halfSize {
	case 1:
		// GF(2^8) element * alpha_GF16 = 16 in GF256.
		// result[0] = gf256Mul(hh[0], 16)
		return []frontend.Variable{g.mulAlpha4.Lookup(hh[0])[0]}

	case 2:
		// GF(2^16) element [a, b] * alpha_GF32 = [0, 1] in GF(2^16).
		// resLo = gf256Mul(b, 16);  resHi = a ^ b
		r0 := g.mulAlpha4.Lookup(hh[1])[0] // gf256Mul(b, 16)
		r1 := g.xorByte(hh[0], hh[1])      // a ^ b  (byte XOR via lookup)
		return []frontend.Variable{r0, r1}

	case 4:
		// GF(2^32) element [a0,a1,a2,a3] * alpha_GF64 = [0,0,1,0].
		// result_lo = [gf256Mul(a3,16), a2^a3];  result_hi = [a0^a2, a1^a3]
		r0 := g.mulAlpha4.Lookup(hh[3])[0] // gf256Mul(a3, 16)
		r1 := g.xorByte(hh[2], hh[3])      // a2 ^ a3
		r2 := g.xorByte(hh[0], hh[2])      // a0 ^ a2
		r3 := g.xorByte(hh[1], hh[3])      // a1 ^ a3
		return []frontend.Variable{r0, r1, r2, r3}

	case 8:
		// GF(2^64) element [a0..a7] * alpha_GF128 = [0,0,0,0,1,0,0,0].
		// result_lo = [gf256Mul(a7,16), a6^a7, a4^a6, a5^a7]
		// result_hi = [a0^a4, a1^a5, a2^a6, a3^a7]
		r0 := g.mulAlpha4.Lookup(hh[7])[0] // gf256Mul(a7, 16)
		r1 := g.xorByte(hh[6], hh[7])      // a6 ^ a7
		r2 := g.xorByte(hh[4], hh[6])      // a4 ^ a6
		r3 := g.xorByte(hh[5], hh[7])      // a5 ^ a7
		r4 := g.xorByte(hh[0], hh[4])      // a0 ^ a4
		r5 := g.xorByte(hh[1], hh[5])      // a1 ^ a5
		r6 := g.xorByte(hh[2], hh[6])      // a2 ^ a6
		r7 := g.xorByte(hh[3], hh[7])      // a3 ^ a7
		return []frontend.Variable{r0, r1, r2, r3, r4, r5, r6, r7}

	default:
		panic(fmt.Sprintf("gf128.mulByAlpha: unsupported halfSize %d (must be 1,2,4,8)", halfSize))
	}
}

// xorByte XORs two byte-valued frontend.Variables using the byteXorTable.
//
// gnark's api.Xor is single-bit only.  Bit-decomposition costs ~24 constraints;
// a lookup table costs ~2-3 constraints.  We use the latter.
func (g *Gadget) xorByte(a, b frontend.Variable) frontend.Variable {
	idx := g.api.Add(g.api.Mul(a, 256), b)
	return g.byteXorTable.Lookup(idx)[0]
}

// xorByteSlices XORs two equal-length []uints.U8 slices.
func (g *Gadget) xorByteSlices(a, b []uints.U8) []uints.U8 {
	out := make([]uints.U8, len(a))
	for i := range a {
		out[i] = uints.U8{Val: g.xorByte(a[i].Val, b[i].Val)}
	}
	return out
}

// xorVars XORs two equal-length []frontend.Variable slices.
// Each variable is treated as a byte (8-bit value).
func (g *Gadget) xorVars(a, b []frontend.Variable) []frontend.Variable {
	out := make([]frontend.Variable, len(a))
	for i := range a {
		out[i] = g.xorByte(a[i], b[i])
	}
	return out
}

// packBytes packs a 16-element []frontend.Variable (LSB-first byte order)
// back into a GF128.
func (g *Gadget) packBytes(res []frontend.Variable) GF128 {
	var loArr [8]uints.U8
	var hiArr [8]uints.U8
	for i := 0; i < 8; i++ {
		loArr[i] = uints.U8{Val: res[i]}
		hiArr[i] = uints.U8{Val: res[i+8]}
	}
	return GF128{
		Lo: g.uapi.PackLSB(loArr[:]...),
		Hi: g.uapi.PackLSB(hiArr[:]...),
	}
}

// ── Compile-time (constant) helpers ─────────────────────────────────────────

func gf4MulConst(a, b uint8) uint8 {
	a0, a1 := a&1, (a>>1)&1
	b0, b1 := b&1, (b>>1)&1
	ll := a0 & b0
	hh := a1 & b1
	m := (a0 ^ a1) & (b0 ^ b1)
	return (ll ^ hh) | (((m ^ ll) & 1) << 1)
}

func gf16MulConst(a, b uint8) uint8 {
	aLo, aHi := a&3, (a>>2)&3
	bLo, bHi := b&3, (b>>2)&3
	ll := gf4MulConst(aLo, bLo)
	hh := gf4MulConst(aHi, bHi)
	m := gf4MulConst(aLo^aHi, bLo^bHi)
	return (ll ^ gf4MulConst(hh, 2)) | (((m ^ ll) & 3) << 2)
}

// gf256MulConst multiplies two GF(2^8) elements using the binius canonical tower.
// Used only at compile time to build the lookup table.
func gf256MulConst(a, b uint8) uint8 {
	aLo, aHi := a&0xF, (a>>4)&0xF
	bLo, bHi := b&0xF, (b>>4)&0xF
	ll := gf16MulConst(aLo, bLo)
	hh := gf16MulConst(aHi, bHi)
	m := gf16MulConst(aLo^aHi, bLo^bHi)
	return (ll ^ gf16MulConst(hh, 4)) | (((m ^ ll) & 0xF) << 4)
}

// uint64ToBytes returns 8 bytes of v in little-endian order.
func uint64ToBytes(v uint64) [8]uint8 {
	var out [8]uint8
	for i := range out {
		out[i] = uint8(v >> (8 * uint(i)))
	}
	return out
}

// ToBytes serialises a GF128 element into 16 uints.U8 in little-endian byte
// order (Lo bytes first, Lo LSB first; then Hi bytes LSB first).
// This is the canonical binius wire format for GF(2^128) elements.
func (g *Gadget) ToBytes(a GF128) [16]uints.U8 {
	var out [16]uints.U8
	loSlice := g.uapi.UnpackLSB(a.Lo)
	hiSlice := g.uapi.UnpackLSB(a.Hi)
	copy(out[:8], loSlice)
	copy(out[8:], hiSlice)
	return out
}

// SelectGF128 returns zero if sel==0, basisVal if sel==1.
// Used for in-circuit twiddle factor accumulation.
// Cost: 2 constraints (one api.Mul per U64 limb's packed value is not directly
// available; we work at the frontend.Variable level on the packed U64).
func SelectGF128(api frontend.API, uapi *uints.BinaryField[uints.U64], sel frontend.Variable, basisVal GF128) GF128 {
	// For a GF128 constant basisVal, we can compute select as Mul(sel, packed_lo)
	// and Mul(sel, packed_hi).  This works because sel is constrained to {0,1}.
	// gnark handles constant folding: if basisVal limbs are compile-time constants,
	// api.Mul(sel, const) is 1 constraint.
	_ = uapi
	loBytes := basisVal.Lo
	hiBytes := basisVal.Hi
	// Extract raw packed values — work at the U8 level to avoid needing
	// a direct U64 scalar multiply on a variable.
	var selLoArr [8]uints.U8
	var selHiArr [8]uints.U8
	for i, b := range uapi.UnpackLSB(loBytes) {
		selLoArr[i] = uints.U8{Val: api.Mul(sel, b.Val)}
	}
	for i, b := range uapi.UnpackLSB(hiBytes) {
		selHiArr[i] = uints.U8{Val: api.Mul(sel, b.Val)}
	}
	return GF128{
		Lo: uapi.PackLSB(selLoArr[:]...),
		Hi: uapi.PackLSB(selHiArr[:]...),
	}
}
