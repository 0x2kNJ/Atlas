// Package transcript implements the binius64 HasherChallenger Fiat-Shamir transcript
// inside a gnark circuit.
//
// The binius64 HasherChallenger<Sha256> state machine (from binius_transcript crate):
//
//   Init:       hasherData = SHA256("") = emptyHash (32 bytes)
//               mode = Sampler (index starts at 32, triggers immediate fill)
//
//   Observe(d): if in Sampler mode → switch to Observer (feed sampler.index as LE u64
//               into hasherData, then append d)
//               if in Observer mode → append d to hasherData
//
//   Sample(n):  if in Observer mode → switch to Sampler (set index=32)
//               while need more bytes:
//                 if index>=32: digest=SHA256(hasherData); hasherData=[digest]; index=0
//                 copy digest[index..] into output; advance index
//
// For the gnark wrapper circuit, the protocol is deterministic: the same sequence of
// Observe / Sample calls happens for every valid binius64 proof.  Each Sample() call
// therefore processes a fixed-length input, enabling use of gnark's fixed-length SHA256.
//
// Simplified model used here (matches Solidity Transcript.sol _fillSamplerBuffer):
//
//   Challenge():
//     digest = SHA256(hasherData)   // full SHA256 with Merkle-Damgård padding
//     hasherData = digest           // reset for next window
//     return digest
//
// This is correct because the Solidity _fillSamplerBuffer does exactly:
//   digest = _sha256(t.hasherData);
//   t.hasherData = abi.encodePacked(digest);
package transcript

import (
	"github.com/consensys/gnark/frontend"
	sha2gadget "github.com/consensys/gnark/std/hash/sha2"
	"github.com/consensys/gnark/std/math/uints"
)

// emptyHashBytes = SHA256("") in big-endian byte order.
// Used to seed the initial hasherData per the binius HasherChallenger default.
var emptyHashBytes = [32]uint8{
	0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
	0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
	0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
	0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
}

// State is the running Fiat-Shamir transcript state inside a gnark circuit.
//
// hasherData corresponds to the binius Solidity _transcript.hasherData:
// it accumulates all observed bytes since the last Challenge() call, prepended
// by the 32-byte result of the previous Challenge() (or the emptyHash seed).
type State struct {
	api  frontend.API
	uapi *uints.BinaryField[uints.U64]

	// hasherData: current SHA256 input buffer.
	// Starts as [emptyHashBytes...], grows with each Absorb() call.
	// After Challenge(), resets to [digest...].
	hasherData []uints.U8
}

// New creates a fresh transcript whose hasherData is seeded with SHA256("").
// This matches HasherChallenger::default() / Transcript::init() in Solidity.
func New(api frontend.API) (*State, error) {
	uapi, err := uints.New[uints.U64](api)
	if err != nil {
		return nil, err
	}
	// Seed with the empty hash as 32 constant bytes.
	seed := make([]uints.U8, 32)
	for i, b := range emptyHashBytes {
		seed[i] = uints.NewU8(b)
	}
	return &State{api: api, uapi: uapi, hasherData: seed}, nil
}

// Absorb appends data bytes to the running hasherData buffer.
// This models the Observer phase of binius HasherChallenger (transitioning
// from Sampler mode is handled automatically by Challenge()).
func (s *State) Absorb(data []uints.U8) {
	s.hasherData = append(s.hasherData, data...)
}

// AbsorbBytes is a convenience wrapper accepting []frontend.Variable (raw byte vars).
func (s *State) AbsorbBytes(data []frontend.Variable) {
	for _, b := range data {
		s.hasherData = append(s.hasherData, uints.U8{Val: b})
	}
}

// AbsorbFieldElement absorbs a BN254 field element into the transcript buffer.
//
// The field element is decomposed into 32 little-endian bytes (254 significant
// bits, then 2 zero-padding bits) before being appended to hasherData.  This
// lets the SHA256-based transcript bind to MiMC Merkle roots without changing
// the transcript hash function.
//
// Constraint cost: ~280 constraints (254 ToBinary + 32 FromBinary).
func (s *State) AbsorbFieldElement(api frontend.API, val frontend.Variable) {
	bits := api.ToBinary(val, 254) // 254 bits, LSB first
	for byteIdx := 0; byteIdx < 32; byteIdx++ {
		var byteBits [8]frontend.Variable
		for bitIdx := 0; bitIdx < 8; bitIdx++ {
			pos := byteIdx*8 + bitIdx
			if pos < 254 {
				byteBits[bitIdx] = bits[pos]
			} else {
				byteBits[bitIdx] = frontend.Variable(0)
			}
		}
		s.hasherData = append(s.hasherData, uints.U8{Val: api.FromBinary(byteBits[:]...)})
	}
}

// AbsorbU32s absorbs a slice of uints.U32 values (e.g. a SHA256 state).
// Each U32 is unpacked MSB-first (big-endian word → 4 bytes) to match the
// Solidity observeBytes32 serialisation.
func (s *State) AbsorbU32s(words []uints.U32) {
	uapi32, _ := uints.New[uints.U32](s.api)
	for _, w := range words {
		bs := uapi32.UnpackMSB(w)
		for _, b := range bs {
			s.hasherData = append(s.hasherData, b)
		}
	}
}

// Challenge finalises the current hasherData window by running gnark's full
// SHA256 (with proper Merkle-Damgård padding) over it, then resets hasherData
// to the resulting 32-byte digest for the next window.
//
// Returns the 32-byte digest as a []uints.U8 slice (big-endian SHA256 output).
//
// Constraint cost: SHA256 of len(hasherData) bytes.
// Typical window ≈ 64 bytes → 1 SHA256 block ≈ 25k PLONK constraints.
func (s *State) Challenge() ([]uints.U8, error) {
	h, err := sha2gadget.New(s.api)
	if err != nil {
		return nil, err
	}
	h.Write(s.hasherData)
	digest := h.Sum() // 32 bytes, big-endian SHA256 output

	// Reset hasherData to just the digest (matches _fillSamplerBuffer reset).
	s.hasherData = make([]uints.U8, 32)
	copy(s.hasherData, digest)

	return digest, nil
}

// ChallengeGF128 draws a GF(2^128) challenge from the transcript.
//
// binius Challenge bytes are interpreted as a 128-bit LE integer: the FIRST
// byte of the SHA256 digest is the LEAST significant byte of the GF128 element.
// SHA256 outputs big-endian bytes, so digest[0] is the MSB of the hash.
// But binius samples 16 bytes and interprets them in LSB-first order (matching
// Rust's from_le_bytes).  The Solidity sampleGF128 byte-reverses the 16 bytes.
//
// This function returns a GF128 (Lo, Hi) pair where:
//   Lo = PackLSB(digest[15], digest[14], ..., digest[8])  (LE of lower limb)
//   Hi = PackLSB(digest[31], digest[30], ..., digest[24]) (LE of upper limb)
//
// — i.e. the challenge bytes are taken in reverse order so byte-0 of the
// LE-integer equals digest[15] (the 16th byte of the SHA256 output).
func (s *State) ChallengeGF128() (lo, hi uints.U64, err error) {
	digest, err := s.Challenge()
	if err != nil {
		return lo, hi, err
	}
	// digest[0..31] are big-endian SHA256 bytes.
	// binius sampleGF128 takes the FIRST 16 bytes of the sample and byte-reverses
	// them: val = bswap128(first16).  Equiv: LE-interpret first 16 bytes.
	// In gnark uints, PackLSB(b0, b1, ..., b7) packs b0 as the least-significant.
	// So lo = PackLSB(digest[15], digest[14], ..., digest[8])  ← bytes 8..15 reversed
	//    hi = PackLSB(digest[31], digest[30], ..., digest[24]) ← bytes 24..31 reversed
	uapi64, _ := uints.New[uints.U64](s.api)
	var loArr [8]uints.U8
	var hiArr [8]uints.U8
	for i := 0; i < 8; i++ {
		loArr[i] = digest[15-i]
		hiArr[i] = digest[31-i]
	}
	lo = uapi64.PackLSB(loArr[:]...)
	hi = uapi64.PackLSB(hiArr[:]...)
	return lo, hi, nil
}
