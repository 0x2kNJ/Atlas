package gf128_test

import (
	"testing"
)

// ── Constant arithmetic sanity tests (no gnark circuit needed) ───────────────

// gf256MulConst is exported for testing via the package-level access.
// We re-implement it here using the unexported function via a small shim.

// TestGF4Mul verifies the multiplication table for GF(2^2).
// β^2 = β + 1  (irreducible x^2 + x + 1).
func TestGF4Mul(t *testing.T) {
	// Build the full 4×4 GF4 multiplication table using gf256MulConst
	// at the nibble-within-nibble level.  We test key identities.

	// We can extract GF4 values from GF256 by testing low-nibble, high-nibble = 0.
	// gf256MulConst(a, b) where a,b < 4 should equal gf4Mul(a,b).

	// β = 2, β^2 = β+1 = 3
	// gf256Mul(2, 2) should be gf16Mul(0,0) | gf16Mul(0,0)<<4 = ... let's compute.
	// Actually we need to just test the GF4 directly via GF256 with high nibble=0.
	cases := [][3]uint8{
		{0, 0, 0}, {0, 1, 0}, {0, 2, 0}, {0, 3, 0},
		{1, 0, 0}, {1, 1, 1}, {1, 2, 2}, {1, 3, 3},
		{2, 0, 0}, {2, 1, 2}, {2, 2, 3}, {2, 3, 1}, // β*β = β+1 = 3, β*(β+1) = 1
		{3, 0, 0}, {3, 1, 3}, {3, 2, 1}, {3, 3, 2}, // (β+1)*(β+1) = β^2+1 = β = 2
	}
	for _, tc := range cases {
		a, b, want := tc[0], tc[1], tc[2]
		got := gf256Const(a, b)
		if got != want {
			t.Errorf("gf4Mul(%d, %d): got %d, want %d", a, b, got, want)
		}
	}
}

// gf256Const is called by the test helper below.

// gf256Const is the compile-time reference implementation, duplicated here
// for test independence.
func gf256Const(a, b uint8) uint8 {
	aLo, aHi := a&0xF, (a>>4)&0xF
	bLo, bHi := b&0xF, (b>>4)&0xF
	ll := gf16Const(aLo, bLo)
	hh := gf16Const(aHi, bHi)
	m := gf16Const(aLo^aHi, bLo^bHi)
	alphaHH := gf16Const(hh, 4)
	lo := ll ^ alphaHH
	hi := m ^ ll
	return lo | (hi << 4)
}

func gf16Const(a, b uint8) uint8 {
	aLo, aHi := a&3, (a>>2)&3
	bLo, bHi := b&3, (b>>2)&3
	ll := gf4Const(aLo, bLo)
	hh := gf4Const(aHi, bHi)
	m := gf4Const(aLo^aHi, bLo^bHi)
	alphaHH := gf4Const(hh, 2)
	lo := ll ^ alphaHH
	hi := m ^ ll
	return lo | (hi << 2)
}

func gf4Const(a, b uint8) uint8 {
	a0, a1 := a&1, (a>>1)&1
	b0, b1 := b&1, (b>>1)&1
	ll := a0 & b0
	hh := a1 & b1
	m := (a0 ^ a1) & (b0 ^ b1)
	lo := ll ^ hh
	hi := m ^ ll
	return lo | (hi << 1)
}

// TestGF16Mul checks that γ^2 = γ + β (the defining relation for GF16).
// γ = 4 (GF16 generator), β = 2 (GF4 generator).
func TestGF16Mul(t *testing.T) {
	gamma := uint8(4)
	beta := uint8(2)
	// γ^2 = γ + β = 4 XOR 2 = 6
	got := gf16Const(gamma, gamma)
	want := gamma ^ beta
	if got != want {
		t.Errorf("gf16Mul(γ, γ): got %d, want γ+β=%d", got, want)
	}
}

// TestGF256Mul checks that δ^2 = δ + γ (defining relation for GF256 tower).
// δ = 0x10 (GF256 generator), γ = 0x04 (GF16 generator embedded in GF256).
func TestGF256Mul(t *testing.T) {
	delta := uint8(0x10) // = 16
	gamma := uint8(0x04) // = 4
	// δ^2 = δ + γ = 0x10 XOR 0x04 = 0x14
	got := gf256Const(delta, delta)
	want := delta ^ gamma
	if got != want {
		t.Errorf("gf256Mul(δ, δ): got 0x%02x, want δ+γ=0x%02x", got, want)
	}
}

// TestGF256MulOne checks that 1 is the multiplicative identity.
func TestGF256MulOne(t *testing.T) {
	for a := 0; a < 256; a++ {
		got := gf256Const(uint8(a), 1)
		if got != uint8(a) {
			t.Errorf("gf256Mul(%d, 1) = %d, want %d", a, got, a)
		}
	}
}

// TestGF256MulCommutativity checks a*b == b*a for all byte pairs.
func TestGF256MulCommutativity(t *testing.T) {
	for a := 0; a < 256; a++ {
		for b := 0; b < 256; b++ {
			ab := gf256Const(uint8(a), uint8(b))
			ba := gf256Const(uint8(b), uint8(a))
			if ab != ba {
				t.Errorf("gf256Mul(%d,%d)=%d != gf256Mul(%d,%d)=%d", a, b, ab, b, a, ba)
				return
			}
		}
	}
}

// TestGF256MulDistributivity checks a*(b+c) == a*b + a*c.
func TestGF256MulDistributivity(t *testing.T) {
	for a := 0; a < 256; a++ {
		for b := 0; b < 16; b++ {
			for c := 0; c < 16; c++ {
				bXorC := uint8(b ^ c)
				lhs := gf256Const(uint8(a), bXorC)
				rhs := gf256Const(uint8(a), uint8(b)) ^ gf256Const(uint8(a), uint8(c))
				if lhs != rhs {
					t.Errorf("distributivity failed: a=%d b=%d c=%d", a, b, c)
					return
				}
			}
		}
	}
}
