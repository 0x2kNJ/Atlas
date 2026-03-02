// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "./lib/GF128.sol";
import "./lib/Transcript.sol";
import "./lib/MerkleLib.sol";
import "./protocols/Sumcheck.sol";
import "./protocols/ShiftReduction.sol";
import "./protocols/AndReduction.sol";
import "./protocols/IntMulReduction.sol";
import "./protocols/BaseFold.sol";
import "./RingSwitch.sol";

/// @title Binius64Verifier -- Main entry point for binius64 proof verification
/// @notice Orchestrates all verification sub-protocols in the correct order,
///         matching the Rust `Verifier::verify_iop` function flow.
///
///         Verification flow (total ~272 KB proof for Encumber circuit):
///           0. Observe public inputs (no proof bytes)
///           1. Trace commitment (32 bytes)
///           2. IntMul reduction (9920 bytes for n_mul=0)
///           3. AND reduction (1648 bytes)
///           4. Shift reduction (976 bytes)
///           5. RingSwitch reduction (2048 bytes)
///           6. BaseFold/FRI (257664 bytes: 17-round sumcheck + 3 commits + terminate_cw + layers + 232 queries)
///           7. Finalize transcript (assert all proof bytes consumed)
contract Binius64Verifier {
    using GF128 for uint256;
    using Transcript for Transcript.State;

    struct ConstraintSystemParams {
        uint256 nWitnessWords;   // total committed words (262144 = 2^18 for Encumber)
        uint256 nPublicWords;    // number of public input words (13 for Encumber, padded to 128)
        uint256 logInvRate;      // FRI rate: 1 for rate 1/2
        uint256 nFriQueries;     // number of FRI test queries (192 for Encumber)
    }

    ConstraintSystemParams public params;

    constructor(ConstraintSystemParams memory _params) {
        params = _params;
    }

    /// @notice Verify a binius64 proof.
    /// @param proof        The serialized proof bytes.
    /// @param publicInputs The 128 public input words (padded, each uint64 as uint256).
    /// @return valid       True if the proof verifies.
    function verify(
        bytes calldata proof,
        uint256[] calldata publicInputs
    ) external view returns (bool valid) {
        Transcript.State memory t = Transcript.init(proof);

        // ---- 0. Observe public inputs (no proof bytes) ----
        for (uint256 i = 0; i < publicInputs.length; i++) {
            bytes memory word = _encodeU64LE(publicInputs[i]);
            t.observe(word);
        }

        // ---- 1. Trace commitment (32 bytes) ----
        bytes32 traceRoot = t.messageBytes32();

        // ---- 2. IntMul reduction (9920 bytes for n_mul=0) ----
        IntMulReduction.IntMulOutput memory intmulOut = IntMulReduction.verify(t, 0);

        // ---- 3. AND reduction (1648 bytes) ----
        AndReduction.AndOutput memory andOut = AndReduction.verify(t);

        // ---- 4. Shift reduction (976 bytes) ----
        uint64[] memory publicWords = _toUint64Array(publicInputs);
        uint256[3] memory andEvals = [andOut.aEval, andOut.bEval, andOut.cEval];
        uint256[4] memory intmulEvals = [uint256(0), uint256(0), uint256(0), uint256(0)];

        ShiftReduction.ShiftOutput memory shiftOut = ShiftReduction.verify(
            t, andEvals, andOut.zChallenge, intmulEvals, 0, publicWords
        );

        // ---- 5. RingSwitch reduction (2048 bytes) ----
        uint256[] memory evalPoint = _buildEvalPoint(shiftOut.rJ, shiftOut.rY);
        RingSwitch.RingSwitchOutput memory rsOut = RingSwitch.verify(
            t, shiftOut.witnessEval, evalPoint
        );

        // ---- 6. BaseFold/FRI (257664 bytes) ----
        BaseFold.BaseFoldOutput memory friOut = BaseFold.verify(
            t, rsOut.sumcheckClaim, traceRoot
        );

        // ---- 7. Finalize (assert all proof bytes consumed) ----
        t.finalize();

        valid = true;
    }

    // ---- Internal helpers ------------------------------------------------

    function _encodeU64LE(uint256 val) internal pure returns (bytes memory b) {
        b = new bytes(8);
        assembly {
            let ptr := add(b, 32)
            mstore8(ptr,           and(val, 0xff))
            mstore8(add(ptr, 1),   and(shr(8,  val), 0xff))
            mstore8(add(ptr, 2),   and(shr(16, val), 0xff))
            mstore8(add(ptr, 3),   and(shr(24, val), 0xff))
            mstore8(add(ptr, 4),   and(shr(32, val), 0xff))
            mstore8(add(ptr, 5),   and(shr(40, val), 0xff))
            mstore8(add(ptr, 6),   and(shr(48, val), 0xff))
            mstore8(add(ptr, 7),   and(shr(56, val), 0xff))
        }
    }

    function _toUint64Array(uint256[] calldata inputs) internal pure returns (uint64[] memory out) {
        out = new uint64[](inputs.length);
        for (uint256 i = 0; i < inputs.length; i++) {
            out[i] = uint64(inputs[i]);
        }
    }

    function _buildEvalPoint(
        uint256[] memory rJ,
        uint256[] memory rY
    ) internal pure returns (uint256[] memory ep) {
        ep = new uint256[](rJ.length + rY.length);
        for (uint256 i = 0; i < rJ.length; i++) ep[i] = rJ[i];
        for (uint256 i = 0; i < rY.length; i++) ep[rJ.length + i] = rY[i];
    }
}
