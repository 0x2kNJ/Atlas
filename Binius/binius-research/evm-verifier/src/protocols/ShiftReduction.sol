// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "../lib/GF128.sol";
import "../lib/Transcript.sol";
import "./Sumcheck.sol";

/// @title ShiftReduction — Shift constraint verification for binius64
/// @notice Verifies the shift protocol that batches AND and MUL constraint evaluations.
///
///         Protocol:
///           1. Sample bitand_lambda, intmul_lambda (no proof bytes)
///           2. Compute initial_eval = bitand_batched_eval + intmul_batched_eval (COMPUTED, not read)
///              where batched_eval(lambda) = lambda * evaluate_univariate([a,b,c], lambda)
///           3. Phase 1: standard sumcheck (degree=2, 12 rounds) with initial_eval as claim
///              → 12 × 2 × 16 = 384 bytes consumed
///              → challenges r_jr_s, reversed → split: r_s = last 6, r_j = first 6
///           4. Sample inout_eval_point (7 challenges, no proof bytes)
///           5. Compute public_eval = evaluate_public_mle(public, r_j, inout_eval_point)
///           6. Sample batch_coeff (no proof bytes)
///           7. phase2_sum = gamma XOR mul(batch_coeff, public_eval)
///           8. Phase 2: standard sumcheck (degree=2, 18 rounds) with phase2_sum as claim
///              → 18 × 2 × 16 = 576 bytes consumed
///              → challenges r_y, reversed
///           9. Read witness_eval (16 bytes)
///           Total proof bytes: 384 + 576 + 16 = 976 bytes
///
///         The AND/IntMul batched_eval is computed from the operator data passed in.
library ShiftReduction {
    using GF128 for uint256;
    using Transcript for Transcript.State;

    uint256 internal constant LOG_WORD_SIZE_BITS = 6;  // log2(64) for 64-bit words
    uint256 internal constant INOUT_N_VARS = 7;        // log2(128 public words)
    uint256 internal constant LOG_WORD_COUNT = 18;     // log2(committed_total_len)

    struct ShiftOutput {
        uint256[] rJ;              // bit-index challenge (length LOG_WORD_SIZE_BITS = 6)
        uint256[] rS;              // shift challenge (length LOG_WORD_SIZE_BITS = 6)
        uint256[] rY;              // word-index challenge (length LOG_WORD_COUNT = 18)
        uint256 witnessEval;       // claimed witness evaluation
        uint256[] inoutEvalPoint;  // eval point for public input verification (length 7)
        uint256 batchCoeff;        // batch coefficient for ring-switch
    }

    /// @notice Verify the shift reduction protocol.
    /// @param t              Fiat-Shamir transcript.
    /// @param andEvals       [a_eval, b_eval, c_eval] from AND reduction.
    /// @param andZChallenge  z_challenge (r_zhat_prime) from AND reduction.
    /// @param intmulEvals    [a0, b0, clo0, chi0] evals from IntMul (or zeros if n_mul=0).
    /// @param intmulZChallenge  r_zhat_prime from IntMul (shared with AND).
    /// @param publicWords    Public input words (uint64 as uint256, LE).
    /// @return output        Verification output with evaluation points and witness eval.
    function verify(
        Transcript.State memory t,
        uint256[3] memory andEvals,
        uint256 andZChallenge,
        uint256[4] memory intmulEvals,
        uint256 intmulZChallenge,
        uint64[] memory publicWords
    ) internal view returns (ShiftOutput memory output) {
        // 1. Sample lambda coefficients
        uint256 bitandLambda = t.sampleGF128();
        uint256 intmulLambda = t.sampleGF128();

        // 2. Compute initial_eval = bitand_data.batched_eval(bitand_lambda) + intmul_data.batched_eval(intmul_lambda)
        //    batched_eval(lambda) = lambda * evaluate_univariate(evals, lambda)
        //    For AND: evals = [a_eval, b_eval, c_eval], univariate poly evaluated at lambda
        //    For IntMul: evals = [a0, b0, clo0, chi0] (or 0 if skipped)
        uint256 bitandPolyEval = _evaluateUnivariate3(andEvals[0], andEvals[1], andEvals[2], bitandLambda);
        uint256 bitandBatchedEval = GF128.mul(bitandLambda, bitandPolyEval);

        uint256 intmulPolyEval = _evaluateUnivariate4(intmulEvals[0], intmulEvals[1], intmulEvals[2], intmulEvals[3], intmulLambda);
        uint256 intmulBatchedEval = GF128.mul(intmulLambda, intmulPolyEval);

        uint256 shiftEval = bitandBatchedEval ^ intmulBatchedEval;

        // 3. Phase 1 sumcheck: 12 rounds, degree=2
        Sumcheck.Result memory sc1 = Sumcheck.verify(t, LOG_WORD_SIZE_BITS * 2, 2, shiftEval);

        // Reverse and split challenges:
        // r_jr_s (reversed) → r_s = first 6 elements, r_j = last 6 elements
        // Wait: binius does r_jr_s.reverse() then split_off(6) → r_s = last 6 of original, r_j = first 6 of original
        // After reverse: [c11, c10, ..., c0]. split_off(6) → r_s = [c5, c4, ..., c0], r_j = [c11, ..., c6]
        output.rJ = new uint256[](LOG_WORD_SIZE_BITS);
        output.rS = new uint256[](LOG_WORD_SIZE_BITS);
        for (uint256 i = 0; i < LOG_WORD_SIZE_BITS; i++) {
            // After reversal: challenge[i] = original_challenge[11-i]
            // r_j = reversed_challenges[0..6] = original_challenges[11..6] in reverse
            // r_s = reversed_challenges[6..12] = original_challenges[5..0] in reverse
            output.rJ[i] = sc1.challenges[LOG_WORD_SIZE_BITS * 2 - 1 - i];
            output.rS[i] = sc1.challenges[LOG_WORD_SIZE_BITS - 1 - i];
        }
        uint256 gamma = sc1.finalEval;

        // 4. Sample inout_eval_point (7 challenges, no proof bytes)
        output.inoutEvalPoint = new uint256[](INOUT_N_VARS);
        for (uint256 i = 0; i < INOUT_N_VARS; i++) {
            output.inoutEvalPoint[i] = t.sampleGF128();
        }

        // 5. Compute public_eval = evaluate_public_mle(public, r_j, inout_eval_point)
        uint256 publicEval = _evaluatePublicMle(publicWords, output.rJ, output.inoutEvalPoint);

        // 6. Sample batch_coeff
        output.batchCoeff = t.sampleGF128();

        // 7. phase2_sum = gamma + batch_coeff * public_eval
        uint256 phase2Sum = gamma ^ GF128.mul(output.batchCoeff, publicEval);

        // 8. Phase 2 sumcheck: 18 rounds, degree=2
        Sumcheck.Result memory sc2 = Sumcheck.verify(t, LOG_WORD_COUNT, 2, phase2Sum);

        // Reverse r_y: r_y[i] = sc2.challenges[LOG_WORD_COUNT - 1 - i]
        output.rY = new uint256[](LOG_WORD_COUNT);
        for (uint256 i = 0; i < LOG_WORD_COUNT; i++) {
            output.rY[i] = sc2.challenges[LOG_WORD_COUNT - 1 - i];
        }

        // 9. Read witness_eval (16 bytes)
        output.witnessEval = t.messageGF128();
    }

    /// @notice Evaluate univariate polynomial a + b*x + c*x^2 at x using Horner.
    function _evaluateUnivariate3(uint256 a, uint256 b, uint256 c, uint256 x) internal pure returns (uint256) {
        return a ^ GF128.mul(x, b ^ GF128.mul(x, c));
    }

    /// @notice Evaluate univariate polynomial a + b*x + c*x^2 + d*x^3 at x using Horner.
    function _evaluateUnivariate4(uint256 a, uint256 b, uint256 c, uint256 d, uint256 x) internal pure returns (uint256) {
        return a ^ GF128.mul(x, b ^ GF128.mul(x, c ^ GF128.mul(x, d)));
    }

    /// @notice Evaluate the MLE of the public inputs at (r_j, inout_eval_point).
    ///
    ///         The public inputs are 128 64-bit words (2^7 words × 2^6 bits = 2^13 total bits).
    ///         The MLE is evaluated as:
    ///           1. For each word w, compute z_folded = sum_{bit i of w} eq_tensor_z[i]
    ///              where eq_tensor_z = eq_ind_partial_eval(r_j) (64 GF128 elements)
    ///           2. Evaluate the 128-element array of z_folded values at inout_eval_point (7 vars)
    ///
    ///         eq_ind_partial_eval(r_j): produces [eq(x, r_j) for x in {0,1}^6]
    ///         For each word w: z_folded_w = inner_product(bits_of_w, eq_tensor_z)
    ///         = sum of eq_tensor_z[i] for each set bit i of w
    ///
    function _evaluatePublicMle(
        uint64[] memory publicWords,
        uint256[] memory rJ,
        uint256[] memory inoutEvalPoint
    ) internal pure returns (uint256) {
        uint256 nWords = publicWords.length;  // should be 128 = 2^7

        // Step 1: Compute eq_tensor_z = eq_ind_partial_eval(r_j)
        // This gives 64 = 2^6 elements: eq_tensor_z[x] = prod_i (x_i*r_j_i + (1-x_i)*(1-r_j_i))
        uint256[64] memory eqTensorZ;
        eqTensorZ[0] = 1; // eq(0...0, r_j) = prod_i (1 - r_j_i) initially
        uint256 currentLen = 1;
        for (uint256 dim = 0; dim < LOG_WORD_SIZE_BITS; dim++) {
            uint256 r = rJ[dim];
            uint256 oneMinusR = 1 ^ r; // In GF(2): 1 - r = 1 XOR r
            // Build the next level: for each existing entry, create two entries
            // eqTensorZ[2*idx+1] = eqTensorZ[idx] * r
            // eqTensorZ[2*idx] = eqTensorZ[idx] * (1-r)
            // We go backwards to avoid overwriting
            for (uint256 j = currentLen; j > 0; j--) {
                uint256 idx = j - 1;
                uint256 val = eqTensorZ[idx];
                eqTensorZ[2 * idx] = GF128.mul(val, oneMinusR);
                eqTensorZ[2 * idx + 1] = GF128.mul(val, r);
            }
            currentLen <<= 1;
        }

        // Step 2: For each public word, compute z_folded_w = inner product of word bits with eq_tensor_z
        // In GF(2^128): bits are 0 or 1, so multiplication by bit is conditional selection
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

        // Step 3: Evaluate the 128-element multilinear at inout_eval_point (7 vars)
        return _evaluateMultilinear(zFoldedWords, inoutEvalPoint);
    }

    /// @notice Evaluate a multilinear polynomial at a point via iterative folding.
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
