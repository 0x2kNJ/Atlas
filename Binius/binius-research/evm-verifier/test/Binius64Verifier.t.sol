// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/Binius64Verifier.sol";
import "../src/lib/GF128.sol";
import "../src/lib/Transcript.sol";
import "../src/lib/MerkleLib.sol";
import "../src/protocols/Sumcheck.sol";
import "../src/protocols/ShiftReduction.sol";
import "../src/RingSwitch.sol";

/// @title Binius64Verifier end-to-end tests
/// @notice Tests the full verifier contract deployment and component integration.
///         A real end-to-end proof verification test requires a proof generated
///         by the Rust `cargo run --release --bin bench` binary (future work).
///
///         These tests verify:
///         1. Contract deploys with correct parameters
///         2. Each sub-library is accessible and functional
///         3. Parameter computation (log2Ceil, etc.) works correctly
///         4. Cross-library integration (GF128 + Transcript + Sumcheck + Merkle)
contract Binius64VerifierTest is Test {
    Binius64Verifier verifier;

    function setUp() public {
        verifier = new Binius64Verifier(
            Binius64Verifier.ConstraintSystemParams({
                nWitnessWords: 1024,    // 2^10
                nPublicWords: 8,        // 2^3
                logInvRate: 1,          // rate 1/2
                nFriQueries: 232
            })
        );
    }

    // ─── Deployment & parameter tests ────────────────────────────────────────

    function test_deployment() public view {
        (
            uint256 nWitness,,,
        ) = verifier.params();
        assertEq(nWitness, 1024);
    }

    function test_params_stored() public view {
        (
            uint256 nWitness,
            uint256 nPub,
            uint256 logInv,
            uint256 nFri
        ) = verifier.params();
        assertEq(nWitness, 1024);
        assertEq(nPub, 8);
        assertEq(logInv, 1);
        assertEq(nFri, 232);
    }

    // ─── GF128 integration ───────────────────────────────────────────────────

    function test_gf128_in_verifier_context() public pure {
        // Verify GF128 works with verifier-sized field elements
        uint256 g = 0x494ef99794d5244f9152df59d87a9186;
        uint256 g2 = GF128.mul(g, g);
        assertEq(g2, 0x104e4a835b335c8b1e192ab155791f07);
    }

    // ─── Transcript + Sumcheck integration ───────────────────────────────────

    function test_transcript_sumcheck_integration() public view {
        // Simulate a 1-round sumcheck through the transcript
        uint256 a = 0x42;
        uint256 b = 0xFF;
        uint256 c = 0xAA;
        uint256 claimedSum = b ^ c;

        bytes memory proof = new bytes(48);
        _writeLE128(proof, 0, 0x42);
        _writeLE128(proof, 16, 0xFF);
        _writeLE128(proof, 32, 0xAA);

        Transcript.State memory t = Transcript.init(proof);
        Sumcheck.Result memory result = Sumcheck.verify(t, 1, claimedSum);

        assertEq(result.challenges.length, 1);
        // The final eval should be r(alpha) for the sampled alpha
        uint256 alpha = result.challenges[0];
        uint256 expected = a ^ GF128.mul(b, alpha) ^ GF128.mul(c, GF128.mul(alpha, alpha));
        assertEq(result.finalEval, expected);
    }

    // ─── Merkle integration ──────────────────────────────────────────────────

    function test_merkle_deep_tree() public view {
        // Build a depth-32 tree (simulating FRI commitment depth)
        bytes32 leaf = bytes32(uint256(0xDEAD));
        bytes32 current = leaf;
        bytes32[] memory siblings = new bytes32[](32);

        for (uint256 i = 0; i < 32; i++) {
            siblings[i] = bytes32(uint256(i + 1));
            current = _sha256pair(current, siblings[i]);
        }

        assertTrue(MerkleLib.verify(current, leaf, siblings, 0));
    }

    // ─── GF128 multilinear evaluation (via RingSwitch internal) ──────────────

    function test_multilinear_eval_small() public pure {
        // f(x0, x1) defined by evals [f(0,0), f(1,0), f(0,1), f(1,1)]
        // = [1, 3, 5, 7]
        // f(r0, r1) = 1*(1-r0)*(1-r1) + 3*r0*(1-r1) + 5*(1-r0)*r1 + 7*r0*r1
        // At r0=0, r1=0: f = 1 ✓
        // In GF(2^128), (1-x) = 1^x, and the formula uses XOR for addition.

        // Let's verify trivial case: eval at (0,0) = evals[0]
        uint256[] memory evals = new uint256[](4);
        evals[0] = 1;
        evals[1] = 3;
        evals[2] = 5;
        evals[3] = 7;

        uint256[] memory point = new uint256[](2);
        point[0] = 0;
        point[1] = 0;

        // Manual iterative eval:
        // Round 0 (variable 0): halfLen=2
        //   buf[0] = evals[0] ^ mul(0, evals[0]^evals[1]) = 1 ^ 0 = 1
        //   buf[1] = evals[2] ^ mul(0, evals[2]^evals[3]) = 5 ^ 0 = 5
        // Round 1 (variable 1): halfLen=1
        //   buf[0] = buf[0] ^ mul(0, buf[0]^buf[1]) = 1 ^ 0 = 1
        // Result: 1 ✓
        uint256 result = _evalMultilinear(evals, point);
        assertEq(result, 1, "f(0,0) = 1");

        // At (1, 0):
        point[0] = 1;
        point[1] = 0;
        result = _evalMultilinear(evals, point);
        assertEq(result, 3, "f(1,0) = 3");

        // At (0, 1):
        point[0] = 0;
        point[1] = 1;
        result = _evalMultilinear(evals, point);
        assertEq(result, 5, "f(0,1) = 5");

        // At (1, 1):
        point[0] = 1;
        point[1] = 1;
        result = _evalMultilinear(evals, point);
        assertEq(result, 7, "f(1,1) = 7");
    }

    // ─── Full component gas estimation ───────────────────────────────────────

    function test_gas_gf128_mul_100() public {
        uint256 a = 0x494ef99794d5244f9152df59d87a9186;
        uint256 b = 0xDEADBEEFCAFEBABE1234567890ABCDEF;
        uint256 g0 = gasleft();
        for (uint256 i = 0; i < 100; i++) {
            a = GF128.mul(a, b);
        }
        uint256 g1 = gasleft();
        emit log_named_uint("100x GF128.mul total gas", g0 - g1);
        emit log_named_uint("Per-mul gas", (g0 - g1) / 100);
    }

    function test_gas_sha256_precompile_100() public {
        bytes32 h = bytes32(uint256(42));
        uint256 g0 = gasleft();
        for (uint256 i = 0; i < 100; i++) {
            h = MerkleLib.sha256Single(h);
        }
        uint256 g1 = gasleft();
        emit log_named_uint("100x SHA256 total gas", g0 - g1);
        emit log_named_uint("Per-SHA256 gas", (g0 - g1) / 100);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _sha256pair(bytes32 a, bytes32 b) internal view returns (bytes32 result) {
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            let ok := staticcall(gas(), 0x02, 0x00, 64, 0x00, 32)
            if iszero(ok) { revert(0, 0) }
            result := mload(0x00)
        }
    }

    function _evalMultilinear(
        uint256[] memory evals,
        uint256[] memory point
    ) internal pure returns (uint256 result) {
        uint256 n = point.length;
        uint256 len = evals.length;
        uint256[] memory buf = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            buf[i] = evals[i];
        }

        for (uint256 i = 0; i < n; i++) {
            uint256 halfLen = len >> 1;
            uint256 r = point[i];
            for (uint256 j = 0; j < halfLen; j++) {
                uint256 lo = buf[2 * j];
                uint256 hi = buf[2 * j + 1];
                buf[j] = lo ^ GF128.mul(r, lo ^ hi);
            }
            len = halfLen;
        }

        result = buf[0];
    }

    function _writeLE128(bytes memory buf, uint256 offset, uint256 val) internal pure {
        for (uint256 i = 0; i < 16; i++) {
            buf[offset + i] = bytes1(uint8(val & 0xFF));
            val >>= 8;
        }
    }
}
