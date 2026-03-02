// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import {BinaryFieldLib} from "./BinaryFieldLib.sol";
import {FiatShamirTranscript} from "./FiatShamirTranscript.sol";

/// @title SumcheckVerifier
/// @notice Verifier for the sumcheck protocol over GF(2^128).
///
///   The sumcheck protocol reduces a claim about a multivariate sum:
///     S = Σ_{x ∈ {0,1}^n} g(x)
///   to a single evaluation claim g(r₁,...,rₙ) = v at a random point.
///
///   The protocol runs in n rounds. In round i, the prover sends a
///   univariate polynomial gᵢ(Xᵢ) of degree ≤ d. The verifier checks:
///     gᵢ(0) + gᵢ(1) = claimed_sum
///   then samples a random challenge rᵢ and sets:
///     claimed_sum_{i+1} = gᵢ(rᵢ)
///
///   After n rounds, the verifier holds r = (r₁,...,rₙ) and the final
///   claimed value g(r) which is checked against an oracle/PCS opening.
///
///   In Binius64, the sumcheck polynomials have degree ≤ 3 (for AND
///   constraints) and the field is GF(2^128).
library SumcheckVerifier {
    using BinaryFieldLib for uint256;
    using FiatShamirTranscript for FiatShamirTranscript.Transcript;

    struct RoundPoly {
        uint256[4] coeffs; // g_i(X) = c0 + c1·X + c2·X² + c3·X³ over GF(2^128)
    }

    struct SumcheckProof {
        RoundPoly[] rounds; // one per variable
    }

    struct SumcheckClaim {
        uint256 claimedSum;   // S = Σ g(x) over GF(2^128)
        uint256 numVariables; // n
    }

    struct SumcheckResult {
        uint256[] challenges;  // r₁,...,rₙ — the random evaluation point
        uint256 finalEval;     // g(r₁,...,rₙ) claimed by the prover
    }

    /// @notice Evaluate a degree-≤3 polynomial at a point in GF(2^128).
    /// @dev g(x) = c0 + c1·x + c2·x² + c3·x³ using Horner's method.
    function evalRoundPoly(RoundPoly memory poly, uint256 x)
        internal
        pure
        returns (uint256)
    {
        // Horner: ((c3·x + c2)·x + c1)·x + c0
        uint256 r = poly.coeffs[3];
        r = BinaryFieldLib.mulGF2_128(r, x) ^ poly.coeffs[2];
        r = BinaryFieldLib.mulGF2_128(r, x) ^ poly.coeffs[1];
        r = BinaryFieldLib.mulGF2_128(r, x) ^ poly.coeffs[0];
        return r;
    }

    /// @notice Verify a sumcheck proof and return the random evaluation point + final claim.
    /// @param claim The original sumcheck claim (sum and number of variables)
    /// @param proof The prover's round polynomials
    /// @param transcript Fiat-Shamir transcript (should already have commitments absorbed)
    /// @return result The challenges and final evaluation claim
    function verify(
        SumcheckClaim memory claim,
        SumcheckProof memory proof,
        FiatShamirTranscript.Transcript memory transcript
    ) internal pure returns (SumcheckResult memory result) {
        require(
            proof.rounds.length == claim.numVariables,
            "SumcheckVerifier: wrong number of rounds"
        );

        result.challenges = new uint256[](claim.numVariables);
        uint256 currentSum = claim.claimedSum;

        for (uint256 i = 0; i < claim.numVariables; i++) {
            RoundPoly memory poly = proof.rounds[i];

            // Absorb the round polynomial into the transcript
            transcript.absorbUint256(poly.coeffs[0]);
            transcript.absorbUint256(poly.coeffs[1]);
            transcript.absorbUint256(poly.coeffs[2]);
            transcript.absorbUint256(poly.coeffs[3]);

            // Check: g_i(0) + g_i(1) = currentSum
            uint256 eval0 = poly.coeffs[0]; // g_i(0) = c0
            uint256 eval1 = poly.coeffs[0] ^ poly.coeffs[1]
                            ^ poly.coeffs[2] ^ poly.coeffs[3]; // g_i(1) = c0+c1+c2+c3
            require(
                (eval0 ^ eval1) == currentSum,
                "SumcheckVerifier: round check failed"
            );

            // Sample challenge r_i
            uint256 ri = transcript.squeeze128();
            result.challenges[i] = ri;

            // Update sum: currentSum = g_i(r_i)
            currentSum = evalRoundPoly(poly, ri);
        }

        result.finalEval = currentSum;
    }

    /// @notice Verify a batched sumcheck where multiple sums are combined.
    /// @dev The verifier first samples a batching coefficient α, then
    ///      combines k claims into one: S' = Σ_j α^j · S_j.
    ///      The prover runs sumcheck on the combined polynomial.
    function verifyBatched(
        SumcheckClaim[] memory claims,
        SumcheckProof memory proof,
        FiatShamirTranscript.Transcript memory transcript
    ) internal pure returns (SumcheckResult memory result) {
        require(claims.length > 0, "SumcheckVerifier: no claims");

        uint256 numVars = claims[0].numVariables;
        for (uint256 i = 1; i < claims.length; i++) {
            require(
                claims[i].numVariables == numVars,
                "SumcheckVerifier: variable count mismatch"
            );
        }

        // Sample batching coefficient
        uint256 alpha = transcript.squeeze128();

        // Compute batched sum: S' = Σ_j α^j · S_j
        uint256 batchedSum = 0;
        uint256 alphaPow = 1; // α^0 = 1
        for (uint256 j = 0; j < claims.length; j++) {
            batchedSum ^= BinaryFieldLib.mulGF2_128(alphaPow, claims[j].claimedSum);
            alphaPow = BinaryFieldLib.mulGF2_128(alphaPow, alpha);
        }

        SumcheckClaim memory combinedClaim = SumcheckClaim({
            claimedSum: batchedSum,
            numVariables: numVars
        });

        return verify(combinedClaim, proof, transcript);
    }
}
