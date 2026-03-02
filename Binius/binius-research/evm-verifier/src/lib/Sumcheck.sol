// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "./GF128.sol";
import "./Transcript.sol";

/// @title Sumcheck — Generic sumcheck verifier over GF(2^128)
/// @notice Implements the sumcheck protocol verification for a claim of the form:
///
///           sum_{x in {0,1}^n} f(x) = claimed_sum
///
///         For a degree-d polynomial per round, the prover sends d coefficients
///         [a_0, a_1, ..., a_{d-1}] (highest coefficient a_d is TRUNCATED and recovered):
///
///           a_d = currentSum XOR a_0 XOR XOR_{j=1}^{d-1} a_j
///
///           (In GF(2^128): sum = a_0 + (a_0 + a_1 + ... + a_d) = a_1 + ... + a_d after reduction)
///
///         Then evaluates p(alpha) = a_0 + a_1*alpha + ... + a_d*alpha^d using Horner's method.
///
///         Supported degrees: 2 (reads 2 coefficients) or 3 (reads 3 coefficients).
library Sumcheck {
    using GF128 for uint256;
    using Transcript for Transcript.State;

    struct Result {
        uint256[] challenges;  // n challenge values: [c_0, ..., c_{n-1}]
        uint256 finalEval;     // p_{n-1}(c_{n-1}): the claimed oracle evaluation
    }

    /// @notice Verify a degree-d sumcheck proof read from the transcript.
    /// @param t          Fiat-Shamir transcript state (proof tape).
    /// @param nVars      Number of variables (= number of rounds).
    /// @param degree     Degree of round polynomials (2 or 3).
    /// @param claimedSum The claimed sum over the boolean hypercube.
    /// @return result    The challenge point and final claimed oracle evaluation.
    function verify(
        Transcript.State memory t,
        uint256 nVars,
        uint256 degree,
        uint256 claimedSum
    ) internal view returns (Result memory result) {
        result.challenges = new uint256[](nVars);
        uint256 currentSum = claimedSum;

        for (uint256 i = 0; i < nVars; i++) {
            // Read `degree` coefficients [a_0, a_1, ..., a_{d-1}] from proof tape.
            // The highest coefficient a_d is truncated by the prover.
            uint256 a0 = t.messageGF128();
            uint256 a1 = t.messageGF128();

            uint256 a2;
            uint256 a3;
            if (degree >= 3) {
                a2 = t.messageGF128();
            }

            // Recover highest coefficient a_d from currentSum:
            // p(0) + p(1) = a_0 + (a_0 + a_1 + ... + a_d) = a_1 + ... + a_d = currentSum
            // => a_d = currentSum XOR a_1 XOR ... XOR a_{d-1}
            if (degree == 2) {
                // Recover a_2: a_2 = currentSum XOR a_1
                a2 = currentSum ^ a1;
            } else {
                // degree == 3: Recover a_3: a_3 = currentSum XOR a_1 XOR a_2
                a3 = currentSum ^ a1 ^ a2;
            }

            // Sample random challenge
            uint256 alpha = t.sampleGF128();
            result.challenges[i] = alpha;

            // Evaluate p(alpha) using Horner's method:
            // p(alpha) = a_0 + a_1*alpha + a_2*alpha^2 [+ a_3*alpha^3]
            if (degree == 2) {
                // a_0 + alpha*(a_1 + alpha*a_2)
                currentSum = a0 ^ GF128.mul(alpha, a1 ^ GF128.mul(alpha, a2));
            } else {
                // a_0 + alpha*(a_1 + alpha*(a_2 + alpha*a_3))
                currentSum = a0 ^ GF128.mul(alpha, a1 ^ GF128.mul(alpha, a2 ^ GF128.mul(alpha, a3)));
            }
        }

        result.finalEval = currentSum;
    }
}
