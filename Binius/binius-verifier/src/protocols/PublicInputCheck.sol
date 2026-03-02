// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "../GF128.sol";
import "../Transcript.sol";
import "./Sumcheck.sol";

/// @title PublicInputCheck — Verify public inputs consistency
/// @notice Verifies that the witness multilinear `w` agrees with the public multilinear `p`
///         on the subdomain. Uses MLE-check (degree-1 sumcheck).
library PublicInputCheck {
    using GF128 for uint256;
    using Transcript for Transcript.State;

    struct PubCheckOutput {
        uint256 eval;
        uint256[] evalPoint;
    }

    function verify(
        Transcript.State memory t,
        uint256[] memory evalPoint,
        uint256 nWitnessVars,
        uint256 nPublicVars,
        uint256 publicEval
    ) internal view returns (PubCheckOutput memory output) {
        uint256[] memory zeroPadded = new uint256[](nWitnessVars);
        for (uint256 i = 0; i < nPublicVars && i < evalPoint.length; i++) {
            zeroPadded[i] = evalPoint[i];
        }

        uint256 claimedSum = publicEval;
        uint256 nVars = nWitnessVars;
        Sumcheck.Result memory sc = Sumcheck.verify(t, nVars, claimedSum);

        output.eval = sc.finalEval;
        output.evalPoint = sc.challenges;
    }
}
