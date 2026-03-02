// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "../GF128.sol";
import "../Transcript.sol";
import "./Sumcheck.sol";

/// @title ShiftReduction — Shift constraint verification for binius64
/// @notice Verifies the shift protocol that batches AND and MUL constraint evaluations.
///
///         Protocol:
///           1. Sample bitand_lambda, intmul_lambda (no proof bytes)
///           2. Compute initial_eval = bitand_batched_eval + intmul_batched_eval (COMPUTED, not read)
///           3. Phase 1: standard sumcheck (degree=2, 12 rounds) with initial_eval as claim
///              → 12 × 2 × 16 = 384 bytes consumed
///              → challenges r_jr_s, reversed → split: r_s = last 6, r_j = first 6
///           4. Sample inout_eval_point (7 challenges, no proof bytes)
///           5. Compute public_eval = evaluate_public_mle(public, r_j, inout_eval_point)
///           6. Sample batch_coeff (no proof bytes)
///           7. phase2_sum = gamma XOR mul(batch_coeff, public_eval)
///           8. Phase 2: standard sumcheck (degree=2, 18 rounds) with phase2_sum as claim
///              → 18 × 2 × 16 = 576 bytes consumed
///           9. Read witness_eval (16 bytes)
///           Total proof bytes: 384 + 576 + 16 = 976 bytes
library ShiftReduction {
    using GF128 for uint256;
    using Transcript for Transcript.State;

    uint256 internal constant LOG_WORD_SIZE_BITS = 6;
    uint256 internal constant INOUT_N_VARS = 7;
    uint256 internal constant LOG_WORD_COUNT = 18;

    struct ShiftOutput {
        uint256[] rJ;
        uint256[] rS;
        uint256[] rY;
        uint256 witnessEval;
        uint256[] inoutEvalPoint;
        uint256 batchCoeff;
    }

    function verify(
        Transcript.State memory t,
        uint256[3] memory andEvals,
        uint256 andZChallenge,
        uint256[4] memory intmulEvals,
        uint256 intmulZChallenge,
        uint64[] memory publicWords
    ) internal view returns (ShiftOutput memory output) {
        uint256 bitandLambda = t.sampleGF128();
        uint256 intmulLambda = t.sampleGF128();

        uint256 bitandPolyEval = _evaluateUnivariate3(andEvals[0], andEvals[1], andEvals[2], bitandLambda);
        uint256 bitandBatchedEval = GF128.mul(bitandLambda, bitandPolyEval);

        uint256 intmulPolyEval = _evaluateUnivariate4(intmulEvals[0], intmulEvals[1], intmulEvals[2], intmulEvals[3], intmulLambda);
        uint256 intmulBatchedEval = GF128.mul(intmulLambda, intmulPolyEval);

        uint256 shiftEval = bitandBatchedEval ^ intmulBatchedEval;

        // Phase 1 sumcheck: 12 rounds, degree=2
        Sumcheck.Result memory sc1 = Sumcheck.verify(t, LOG_WORD_SIZE_BITS * 2, 2, shiftEval);

        output.rJ = new uint256[](LOG_WORD_SIZE_BITS);
        output.rS = new uint256[](LOG_WORD_SIZE_BITS);
        for (uint256 i = 0; i < LOG_WORD_SIZE_BITS; i++) {
            output.rJ[i] = sc1.challenges[LOG_WORD_SIZE_BITS * 2 - 1 - i];
            output.rS[i] = sc1.challenges[LOG_WORD_SIZE_BITS - 1 - i];
        }
        uint256 gamma = sc1.finalEval;

        output.inoutEvalPoint = new uint256[](INOUT_N_VARS);
        for (uint256 i = 0; i < INOUT_N_VARS; i++) {
            output.inoutEvalPoint[i] = t.sampleGF128();
        }

        uint256 publicEval = _evaluatePublicMle(publicWords, output.rJ, output.inoutEvalPoint);

        output.batchCoeff = t.sampleGF128();

        uint256 phase2Sum = gamma ^ GF128.mul(output.batchCoeff, publicEval);

        // Phase 2 sumcheck: 18 rounds, degree=2
        Sumcheck.Result memory sc2 = Sumcheck.verify(t, LOG_WORD_COUNT, 2, phase2Sum);

        output.rY = new uint256[](LOG_WORD_COUNT);
        for (uint256 i = 0; i < LOG_WORD_COUNT; i++) {
            output.rY[i] = sc2.challenges[LOG_WORD_COUNT - 1 - i];
        }

        output.witnessEval = t.messageGF128();
    }

    function _evaluateUnivariate3(uint256 a, uint256 b, uint256 c, uint256 x) internal pure returns (uint256) {
        return a ^ GF128.mul(x, b ^ GF128.mul(x, c));
    }

    function _evaluateUnivariate4(uint256 a, uint256 b, uint256 c, uint256 d, uint256 x) internal pure returns (uint256) {
        return a ^ GF128.mul(x, b ^ GF128.mul(x, c ^ GF128.mul(x, d)));
    }

    function _evaluatePublicMle(
        uint64[] memory publicWords,
        uint256[] memory rJ,
        uint256[] memory inoutEvalPoint
    ) internal pure returns (uint256) {
        uint256 nWords = publicWords.length;

        uint256[64] memory eqTensorZ;
        eqTensorZ[0] = 1;
        uint256 currentLen = 1;
        for (uint256 dim = 0; dim < LOG_WORD_SIZE_BITS; dim++) {
            uint256 r = rJ[dim];
            uint256 oneMinusR = 1 ^ r;
            for (uint256 j = currentLen; j > 0; j--) {
                uint256 idx = j - 1;
                uint256 val = eqTensorZ[idx];
                eqTensorZ[2 * idx] = GF128.mul(val, oneMinusR);
                eqTensorZ[2 * idx + 1] = GF128.mul(val, r);
            }
            currentLen <<= 1;
        }

        uint256[] memory zFoldedWords = new uint256[](nWords);
        for (uint256 w = 0; w < nWords; w++) {
            uint64 word = publicWords[w];
            uint256 acc = 0;
            for (uint256 bit = 0; bit < 64; bit++) {
                if ((word >> bit) & 1 == 1) {
                    acc = acc ^ eqTensorZ[bit];
                }
            }
            zFoldedWords[w] = acc;
        }

        return _evaluateMultilinear(zFoldedWords, inoutEvalPoint);
    }

    function _evaluateMultilinear(
        uint256[] memory evals,
        uint256[] memory point
    ) internal pure returns (uint256) {
        uint256 n = point.length;
        uint256 len = evals.length;
        uint256[] memory buf = new uint256[](len);
        for (uint256 i = 0; i < len; i++) buf[i] = evals[i];

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
        return buf[0];
    }
}
