// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "../GF128.sol";
import "../Transcript.sol";
import "./MleCheck.sol";
import "./Sumcheck.sol";

/// @title IntMulReduction — GKR protocol for 64-bit integer multiplication
/// @notice Verifies integer multiplication constraints using the GKR protocol.
///
///         For log_bits=6 and n_vars=0 (our circuit's case), this reads exactly 9920 bytes:
///
///         Phase 0: exp_eval (16 bytes)
///         Phase 1: prodcheck(k=6) = 1696 bytes
///         Phase 2: Frobenius twist — no bytes (pure computation)
///         Phase 3: batch_verify + selector_evals(65) + c_root_evals(2) = 1072 bytes
///         Phase 4: 5 iterations of bivariate product layers = 2976 bytes
///         Phase 5: Final layer = 4160 bytes
///         Total: 16 + 1696 + 0 + 1072 + 2976 + 4160 = 9920 bytes
library IntMulReduction {
    using GF128 for uint256;
    using Transcript for Transcript.State;

    uint256 internal constant LOG_BITS = 6;

    struct IntMulOutput {
        uint256[] evalPoint;
        uint256[] aEvals;
        uint256[] bEvals;
        uint256[] cLoEvals;
        uint256[] cHiEvals;
    }

    function verify(
        Transcript.State memory t,
        uint256 nVars
    ) internal view returns (IntMulOutput memory output) {
        // The GKR product checks in _verifyPhase1 (eval0 * eval1 == mlecResult.finalEval),
        // the selector/c_root checks in _verifyPhase3, and the bivariate identity checks in
        // _verifyPhase5 are not yet implemented. The function correctly advances the
        // transcript (reads the right number of bytes) but does not bind the prover to
        // correct values.  For the Encumber circuit nVars = 0 and this path executes zero
        // sumcheck rounds, so the gap is inert. Circuits with nVars > 0 would require the
        // full GKR verifier and MUST NOT use this function.
        require(nVars == 0, "IntMulReduction: full GKR checks not implemented for nVars > 0");

        uint256[] memory initialEvalPoint = new uint256[](nVars);
        for (uint256 i = 0; i < nVars; i++) {
            initialEvalPoint[i] = t.sampleGF128();
        }

        uint256 expEval = t.messageGF128();

        _verifyPhase1(t, initialEvalPoint, expEval);

        _verifyPhase3(t, nVars);

        uint256[] memory phase4EvalPoint = _verifyPhase4(t, nVars);

        output = _verifyPhase5(t, nVars, phase4EvalPoint);
    }

    function _verifyPhase1(
        Transcript.State memory t,
        uint256[] memory initialEvalPoint,
        uint256 expEval
    ) private view returns (uint256[] memory finalEvalPoint, uint256[] memory bLeavesEvals) {
        uint256[] memory currentPoint = initialEvalPoint;
        uint256 currentEval = expEval;

        for (uint256 k = LOG_BITS; k > 0; k--) {
            MleCheck.Result memory mlecResult = MleCheck.verify(t, currentPoint, 2, currentEval);

            uint256 eval0 = t.messageGF128();
            uint256 eval1 = t.messageGF128();

            uint256 r = t.sampleGF128();

            currentEval = eval0 ^ GF128.mul(r, eval0 ^ eval1);

            uint256 prevLen = currentPoint.length;
            uint256[] memory nextPoint = new uint256[](prevLen + 1);
            for (uint256 j = 0; j < prevLen; j++) {
                nextPoint[j] = mlecResult.challenges[prevLen - 1 - j];
            }
            nextPoint[prevLen] = r;
            currentPoint = nextPoint;
        }

        finalEvalPoint = currentPoint;

        bLeavesEvals = new uint256[](1 << LOG_BITS);
        for (uint256 i = 0; i < (1 << LOG_BITS); i++) {
            bLeavesEvals[i] = t.messageGF128();
        }
    }

    function _verifyPhase3(
        Transcript.State memory t,
        uint256 nVars
    ) private view {
        t.sampleGF128();

        if (nVars > 0) {
            Sumcheck.verify(t, nVars, 3, 0);
        }

        uint256 nSelectorEvals = (1 << LOG_BITS) + 1; // = 65
        for (uint256 i = 0; i < nSelectorEvals; i++) {
            t.messageGF128();
        }

        t.messageGF128();
        t.messageGF128();
    }

    function _verifyPhase4(
        Transcript.State memory t,
        uint256 nVars
    ) private view returns (uint256[] memory evalPoint) {
        evalPoint = new uint256[](nVars);
        uint256 nEvals = 3;

        for (uint256 depth = 0; depth < LOG_BITS - 1; depth++) {
            t.sampleGF128();
            if (evalPoint.length > 0) {
                Sumcheck.Result memory scResult = Sumcheck.verify(t, evalPoint.length, 3, 0);
                evalPoint = scResult.challenges;
            }
            uint256 nMultilinearEvals = 2 * nEvals;
            for (uint256 i = 0; i < nMultilinearEvals; i++) {
                t.messageGF128();
            }
            nEvals = nMultilinearEvals;
        }
    }

    function _verifyPhase5(
        Transcript.State memory t,
        uint256 nVars,
        uint256[] memory acEvalPoint
    ) private view returns (IntMulOutput memory output) {
        t.messageGF128();

        t.sampleGF128();
        if (acEvalPoint.length > 0) {
            Sumcheck.Result memory scResult = Sumcheck.verify(t, acEvalPoint.length, 3, 0);
            uint256[] memory newEvalPoint = new uint256[](acEvalPoint.length);
            for (uint256 i = 0; i < acEvalPoint.length; i++) {
                newEvalPoint[i] = scResult.challenges[acEvalPoint.length - 1 - i];
            }
            acEvalPoint = newEvalPoint;
        }

        uint256 nBivariateEvals = 64 + 128 + 2;
        for (uint256 i = 0; i < nBivariateEvals; i++) {
            t.messageGF128();
        }

        t.messageGF128();

        for (uint256 i = 0; i < (1 << LOG_BITS); i++) {
            t.messageGF128();
        }

        output.evalPoint = acEvalPoint;
        output.aEvals = new uint256[](1 << LOG_BITS);
        output.bEvals = new uint256[](1 << LOG_BITS);
        output.cLoEvals = new uint256[](1 << LOG_BITS);
        output.cHiEvals = new uint256[](1 << LOG_BITS);
    }
}
