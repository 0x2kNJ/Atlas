// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "../GF128.sol";
import "../Transcript.sol";

/// @title MleCheck — MLE-check protocol (Gruen24 Section 3)
/// @notice Implements the MLE-check protocol from binius, which differs from standard
///         sumcheck in two ways:
///
///           1. It iterates through the PRE-DETERMINED evaluation point in REVERSE.
///           2. The prover truncates the LOWEST coefficient (a_0), not the highest.
///
///         For each round, with pre-determined coordinate z_i:
///           - Prover sends [a_1, a_2, ..., a_d] (truncates a_0)
///           - Verifier recovers: a_0 = eval - z_i * (a_1 + a_2 + ... + a_d)
///           - Samples random challenge r_i
///           - Sets eval = p(r_i) = a_0 + a_1*r_i + ... + a_d*r_i^d
///
///         The "claim" is:  eval = sum_{x in {0,1}^n} F(x) * eq(x, point)
///         This reduces to an oracle evaluation at the sampled challenge point.
///
///         Supported degree: 2 (reads 2 coefficients per round).
library MleCheck {
    using GF128 for uint256;
    using Transcript for Transcript.State;

    struct Result {
        uint256[] challenges;  // challenges sampled during mlecheck (in round order)
        uint256 finalEval;     // final evaluation after all rounds
    }

    /// @notice Run MLE-check protocol with pre-determined challenges.
    /// @param t       Fiat-Shamir transcript.
    /// @param point   Pre-determined evaluation point (iterated in REVERSE by the protocol).
    ///                Length = n_vars.
    /// @param degree  Degree of the round polynomial (binius uses degree=2).
    /// @param eval    Initial claimed MLE evaluation.
    /// @return result Challenge array and final eval.
    function verify(
        Transcript.State memory t,
        uint256[] memory point,
        uint256 degree,
        uint256 eval
    ) internal view returns (Result memory result) {
        uint256 nVars = point.length;
        result.challenges = new uint256[](nVars);

        for (uint256 i = 0; i < nVars; i++) {
            // z_i = point[nVars - 1 - i] (reverse iteration)
            uint256 zi = point[nVars - 1 - i];

            uint256 a1 = t.messageGF128();
            uint256 a2;
            if (degree >= 2) {
                a2 = t.messageGF128();
            }

            // Recover a_0 = eval XOR mul(z_i, a_1 XOR a_2)
            uint256 a0;
            if (degree == 2) {
                a0 = eval ^ GF128.mul(zi, a1 ^ a2);
            } else {
                revert("MleCheck: unsupported degree");
            }

            uint256 ri = t.sampleGF128();
            result.challenges[i] = ri;

            eval = a0 ^ GF128.mul(ri, a1 ^ GF128.mul(ri, a2));
        }

        result.finalEval = eval;
    }

    /// @notice Evaluate a univariate polynomial in coefficient form using Horner's method.
    function evaluateUnivariate(uint256[] memory coeffs, uint256 x) internal pure returns (uint256 result) {
        uint256 d = coeffs.length;
        if (d == 0) return 0;
        result = coeffs[d - 1];
        for (uint256 i = d - 1; i > 0; i--) {
            result = coeffs[i - 1] ^ GF128.mul(x, result);
        }
    }
}
