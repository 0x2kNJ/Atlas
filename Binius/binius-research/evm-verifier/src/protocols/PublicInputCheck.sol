// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "../lib/GF128.sol";
import "../lib/Transcript.sol";
import "./Sumcheck.sol";

/// @title PublicInputCheck — Verify public inputs consistency
/// @notice Verifies that the witness multilinear `w` agrees with the public multilinear `p`
///         on the subdomain. Uses MLE-check (degree-1 sumcheck).
///
///         Protocol:
///           1. Receive evaluation point from shift reduction (inoutEvalPoint)
///           2. Evaluate public MLE at the challenge point
///           3. Run degree-1 sumcheck to verify w(x) = p(x) on the subdomain
///           4. Return final evaluation point for the polynomial commitment check
library PublicInputCheck {
    using GF128 for uint256;
    using Transcript for Transcript.State;

    struct PubCheckOutput {
        uint256 eval;            // evaluation of (w - p) at eval_point
        uint256[] evalPoint;     // evaluation point from MLE-check
    }

    /// @notice Verify public input consistency.
    /// @param t             Fiat-Shamir transcript.
    /// @param evalPoint     Evaluation point from shift reduction.
    /// @param nWitnessVars  Number of witness variables.
    /// @param nPublicVars   Number of public input variables.
    /// @param publicEval    Pre-computed evaluation of public MLE at evalPoint.
    /// @return output       Verification output.
    function verify(
        Transcript.State memory t,
        uint256[] memory evalPoint,
        uint256 nWitnessVars,
        uint256 nPublicVars,
        uint256 publicEval
    ) internal view returns (PubCheckOutput memory output) {
        // Zero-pad the eval point: [challenge || 0^{nWitnessVars - nPublicVars}]
        uint256[] memory zeroPadded = new uint256[](nWitnessVars);
        for (uint256 i = 0; i < nPublicVars && i < evalPoint.length; i++) {
            zeroPadded[i] = evalPoint[i];
        }
        // Remaining are already 0

        // The claimed sum for the MLE-check
        uint256 claimedSum = publicEval;

        // Read the sumcheck proof from transcript
        // MLE-check uses degree-1 sumcheck (but our generic sumcheck handles degree-2;
        // degree-1 is just c=0 in each round)
        uint256 nVars = nWitnessVars;
        Sumcheck.Result memory sc = Sumcheck.verify(t, nVars, claimedSum);

        output.eval = sc.finalEval;
        output.evalPoint = sc.challenges;
    }
}
