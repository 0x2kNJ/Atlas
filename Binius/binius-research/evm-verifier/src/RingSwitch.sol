// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "./lib/GF128.sol";
import "./lib/Transcript.sol";

/// @title RingSwitch — Ring-switching reduction for binius64
/// @notice Reduces from a GF(2^128) evaluation claim to a GF(2) sumcheck claim.
///
///         Protocol:
///           1. Read 128 s_hat_v values from proof (2048 bytes)
///           2. Compute eval_point_low = evalPoint[0..7] (FIRST 7 elements, NOT the last 7)
///           3. Verify: evaluateMultilinear(s_hat_v, eval_point_low) == evaluationClaim
///           4. Transpose: s_hat_u = transpose(s_hat_v)  (128×128 bit-matrix transpose)
///           5. Sample r'' (7 challenges, no proof bytes)
///           6. Output: sumcheckClaim = evaluateMultilinear(s_hat_u, r'')
library RingSwitch {
    using GF128 for uint256;
    using Transcript for Transcript.State;

    uint256 internal constant LOG_PACKING = 7; // log2(128) — packing dimension

    struct RingSwitchOutput {
        uint256 sumcheckClaim;    // sumcheck claim for BaseFold (the FRI inner product)
        uint256[] rDoublePrime;   // 7 challenges for row batching
    }

    /// @notice Verify the ring-switch reduction.
    /// @param t               Fiat-Shamir transcript.
    /// @param evaluationClaim Expected GF(2^128) evaluation from shift reduction.
    /// @param evalPoint       Evaluation point: concat(r_j[0..6], r_y[0..18]) = 24 elements.
    /// @return output         Sumcheck claim for BaseFold.
    function verify(
        Transcript.State memory t,
        uint256 evaluationClaim,
        uint256[] memory evalPoint
    ) internal view returns (RingSwitchOutput memory output) {
        uint256 packingSize = 1 << LOG_PACKING; // 128

        // ─── 1. Read s_hat_v: 128 GF128 values (2048 bytes) ─────────────────
        uint256[] memory sHatV = new uint256[](packingSize);
        for (uint256 i = 0; i < packingSize; i++) {
            sHatV[i] = t.messageGF128();
        }

        // ─── 2. Compute eval_point_low = first LOG_PACKING elements ─────────
        // The evaluation point is [r_j[0..6], r_y[0..18]] (24 elements total)
        // eval_point_low = evalPoint[0..7] = [r_j[0..6], r_y[0]]
        uint256[] memory evalPointLow = new uint256[](LOG_PACKING);
        for (uint256 i = 0; i < LOG_PACKING; i++) {
            evalPointLow[i] = (i < evalPoint.length) ? evalPoint[i] : 0;
        }

        // ─── 3. Verify partial evaluation ───────────────────────────────────
        uint256 partialEval = _evaluateMultilinear(sHatV, evalPointLow);
        require(partialEval == evaluationClaim, "RingSwitch: partial eval mismatch");

        // ─── 4. Transpose s_hat_v to get s_hat_u ────────────────────────────
        uint256[] memory sHatU = _transpose(sHatV);

        // ─── 5. Sample r'' challenges ────────────────────────────────────────
        output.rDoublePrime = new uint256[](LOG_PACKING);
        for (uint256 i = 0; i < LOG_PACKING; i++) {
            output.rDoublePrime[i] = t.sampleGF128();
        }

        // ─── 6. Compute sumcheck claim ───────────────────────────────────────
        output.sumcheckClaim = _evaluateMultilinear(sHatU, output.rDoublePrime);
    }

    /// @notice Evaluate a multilinear polynomial at a given point via iterative folding.
    function _evaluateMultilinear(
        uint256[] memory evals,
        uint256[] memory point
    ) internal pure returns (uint256 result) {
        uint256 n = point.length;
        require(evals.length == (1 << n), "RingSwitch: wrong evals length");

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

        result = buf[0];
    }

    /// @notice Transpose a 128×128 bit-matrix represented as 128 GF(2^128) elements.
    ///         u[j] bit i = v[i] bit j
    function _transpose(uint256[] memory v) internal pure returns (uint256[] memory u) {
        uint256 n = v.length; // 128
        u = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j < n; j++) {
                uint256 bit = (v[i] >> j) & 1;
                if (bit != 0) {
                    u[j] = u[j] | (1 << i);
                }
            }
        }
    }
}
