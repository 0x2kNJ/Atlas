// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "../lib/GF128.sol";
import "../lib/Transcript.sol";

/// @title Sumcheck — Generic sumcheck verifier over GF(2^128)
/// @notice Implements the sumcheck protocol verification for a claim of the form:
///
///           sum_{x in {0,1}^n} f(x) = claimed_sum
///
///         For a degree-d polynomial per round, the prover sends d coefficients
///         [a_0, a_1, ..., a_{d-1}] (highest coefficient a_d is TRUNCATED and recovered):
///
///           a_d = currentSum XOR a_1 XOR a_2 XOR ... XOR a_{d-1}
///           because p(0)+p(1) = a_0 + (a_0+a_1+...+a_d) = a_1+...+a_d = currentSum
///
///         Evaluates p(alpha) using Horner's method.
///         Supported degrees: 2 (reads 2 coefficients) or 3 (reads 3 coefficients).
library Sumcheck {
    using GF128 for uint256;
    using Transcript for Transcript.State;

    struct Result {
        uint256[] challenges;  // n challenge values sampled per round (alias: evalPoint)
        uint256 finalEval;     // final evaluation after all rounds
    }

    // Backward-compat struct used by some tests
    struct RoundPoly {
        uint256 a; // constant term
        uint256 b; // linear coefficient
        uint256 c; // quadratic coefficient
    }

    /// @notice Verify a degree-2 sumcheck from transcript (default degree=2 overload).
    function verify(
        Transcript.State memory t,
        uint256 nVars,
        uint256 claimedSum
    ) internal view returns (Result memory result) {
        return verify(t, nVars, 2, claimedSum);
    }

    /// @notice Verify a degree-d sumcheck proof read from the transcript.
    function verify(
        Transcript.State memory t,
        uint256 nVars,
        uint256 degree,
        uint256 claimedSum
    ) internal view returns (Result memory result) {
        result.challenges = new uint256[](nVars);
        uint256 currentSum = claimedSum;

        for (uint256 i = 0; i < nVars; i++) {
            uint256 a0 = t.messageGF128();
            uint256 a1 = t.messageGF128();
            uint256 a2;
            uint256 a3;

            if (degree == 2) {
                // Recover a_2 = currentSum XOR a_1
                a2 = currentSum ^ a1;
            } else {
                // degree == 3: read a_2, recover a_3 = currentSum XOR a_1 XOR a_2
                a2 = t.messageGF128();
                a3 = currentSum ^ a1 ^ a2;
            }

            // Sample random challenge
            uint256 alpha = t.sampleGF128();
            result.challenges[i] = alpha;

            // Evaluate p(alpha) via Horner's method
            if (degree == 2) {
                currentSum = a0 ^ GF128.mul(alpha, a1 ^ GF128.mul(alpha, a2));
            } else {
                currentSum = a0 ^ GF128.mul(alpha, a1 ^ GF128.mul(alpha, a2 ^ GF128.mul(alpha, a3)));
            }
        }

        result.finalEval = currentSum;
    }

    /// @notice Backward-compatible verifyWithArrays for tests.
    ///         Takes pre-provided challenges (not sampled from transcript).
    function verifyWithArrays(
        uint256 nVars,
        uint256 claimedSum,
        RoundPoly[] memory rounds,
        uint256[] memory challenges
    ) internal pure returns (uint256 finalEval) {
        uint256 currentSum = claimedSum;

        for (uint256 i = 0; i < nVars; i++) {
            uint256 a0 = rounds[i].a;
            uint256 a1 = rounds[i].b;
            uint256 a2 = currentSum ^ a1; // Recover a_2 for degree-2

            // Check: a1 ^ a2 == currentSum (this is the consistency check)
            // In GF(2): a1 ^ a2 = a1 ^ (currentSum ^ a1) = currentSum ✓
            // But the old API provided a2 = rounds[i].c explicitly, let's use that
            // and check consistency against currentSum:
            uint256 a2_explicit = rounds[i].c;
            require(a1 ^ a2_explicit == currentSum, "Sumcheck: round check failed");

            uint256 alpha = challenges[i];
            currentSum = a0 ^ GF128.mul(alpha, a1 ^ GF128.mul(alpha, a2_explicit));
        }
        finalEval = currentSum;
    }
}
