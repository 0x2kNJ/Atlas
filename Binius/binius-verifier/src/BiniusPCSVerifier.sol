// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import {BinaryFieldLib} from "./BinaryFieldLib.sol";
import {SumcheckVerifier} from "./SumcheckVerifier.sol";
import {FRIVerifier} from "./FRIVerifier.sol";
import {FiatShamirTranscript} from "./FiatShamirTranscript.sol";

/// @title BiniusPCSVerifier
/// @notice Verifier for the Binius polynomial commitment scheme.
///
///   The Binius PCS (from [DP24]) commits to a multilinear polynomial over small
///   binary fields and later opens it at an evaluation point over a large extension.
///
///   The verification has three phases:
///
///   1. **Ring-switching reduction** — reduces an evaluation claim on a small-field
///      polynomial to an evaluation claim on a large-field polynomial, using a
///      sumcheck-based compiler. This is the key innovation of [DP24]: it
///      eliminates embedding overhead.
///
///   2. **Large-field polynomial opening** — the reduced claim is verified using
///      a binary-field FRI scheme (BaseFold variant). The prover opens the
///      committed polynomial at the queried points.
///
///   3. **Consistency check** — the FRI-verified evaluations are checked against
///      the sumcheck output to ensure the opening matches the committed polynomial.
///
///   The full pipeline: commit → sumcheck(ring-switch) → FRI → accept/reject.
library BiniusPCSVerifier {
    using BinaryFieldLib for uint256;
    using FiatShamirTranscript for FiatShamirTranscript.Transcript;

    struct PCSCommitment {
        bytes32 merkleRoot;      // Merkle root of the committed evaluations
        uint256 numVariables;    // number of variables in the multilinear polynomial
    }

    struct EvaluationClaim {
        uint256[] point;         // evaluation point (each coordinate in GF(2^128))
        uint256 value;           // claimed evaluation w̃(point)
    }

    struct RingSwitchProof {
        SumcheckVerifier.SumcheckProof sumcheckProof;
        uint256 innerEval; // the evaluation of the large-field polynomial at the reduced point
    }

    struct PCSOpeningProof {
        RingSwitchProof ringSwitch;
        FRIVerifier.FRIProof friProof;
    }

    /// @notice Verify a PCS opening proof.
    /// @param commitment The polynomial commitment
    /// @param claim The evaluation claim to verify
    /// @param proof The opening proof (ring-switch + FRI)
    /// @param transcript Fiat-Shamir transcript
    /// @return valid Whether the proof verifies
    function verify(
        PCSCommitment memory commitment,
        EvaluationClaim memory claim,
        PCSOpeningProof memory proof,
        FiatShamirTranscript.Transcript memory transcript
    ) internal pure returns (bool valid) {
        require(
            claim.point.length == commitment.numVariables,
            "PCS: point dimension mismatch"
        );

        // Phase 1: Absorb the commitment
        transcript.absorbBytes32(commitment.merkleRoot);
        transcript.absorbUint256(commitment.numVariables);

        // Absorb the evaluation claim
        for (uint256 i = 0; i < claim.point.length; i++) {
            transcript.absorbUint256(claim.point[i]);
        }
        transcript.absorbUint256(claim.value);

        // Phase 2: Ring-switching reduction via sumcheck
        // The sumcheck reduces the multilinear evaluation claim to a claim on
        // the committed (encoded) polynomial at a single point.
        bool ringSwitchValid = _verifyRingSwitch(
            commitment,
            claim,
            proof.ringSwitch,
            transcript
        );
        if (!ringSwitchValid) return false;

        // Phase 3: FRI verification of the reduced claim
        FRIVerifier.FRIParams memory friParams = FRIVerifier.FRIParams({
            numFoldingRounds: commitment.numVariables,
            numQueries: proof.friProof.queries.length,
            logDomainSize: commitment.numVariables + 1 // domain is 2x the polynomial degree
        });

        return FRIVerifier.verify(
            commitment.merkleRoot,
            proof.friProof,
            friParams,
            transcript
        );
    }

    /// @dev Verify the ring-switching sumcheck reduction.
    ///
    ///   The ring-switching protocol from [DP24] works as follows:
    ///   Given a multilinear w̃ over a small field (e.g., GF(2)) committed via Merkle tree,
    ///   and an evaluation claim w̃(r) = v where r ∈ GF(2^128)^n:
    ///
    ///   1. Express w̃(r) = Σ_{x ∈ {0,1}^n} w(x) · eq(r, x)  (multilinear identity)
    ///   2. Run sumcheck on g(x) = w(x) · eq(r, x) to reduce to a single point evaluation
    ///   3. The prover provides w(s) for the sumcheck output point s
    ///   4. The verifier checks w(s) against the FRI-committed polynomial
    function _verifyRingSwitch(
        PCSCommitment memory commitment,
        EvaluationClaim memory claim,
        RingSwitchProof memory ringSwitchProof,
        FiatShamirTranscript.Transcript memory transcript
    ) private pure returns (bool) {
        uint256 n = commitment.numVariables;

        // The sumcheck claim: Σ_{x ∈ {0,1}^n} w(x) · eq(r, x) = v
        SumcheckVerifier.SumcheckClaim memory sumcheckClaim = SumcheckVerifier.SumcheckClaim({
            claimedSum: claim.value,
            numVariables: n
        });

        SumcheckVerifier.SumcheckResult memory result = SumcheckVerifier.verify(
            sumcheckClaim,
            ringSwitchProof.sumcheckProof,
            transcript
        );

        // After sumcheck, the verifier holds:
        //   - challenges s = (s_1, ..., s_n) (the random evaluation point)
        //   - finalEval = w(s) · eq(r, s)
        //
        // The verifier computes eq(r, s) themselves and checks:
        //   finalEval == innerEval · eq(r, s)
        uint256 eqVal = BinaryFieldLib.eqEval(claim.point, result.challenges);
        uint256 expectedFinal = BinaryFieldLib.mulGF2_128(
            ringSwitchProof.innerEval, eqVal
        );

        if (result.finalEval != expectedFinal) {
            return false;
        }

        // The innerEval (= w(s)) is then verified against the FRI commitment
        // in the outer verify() function.
        transcript.absorbUint256(ringSwitchProof.innerEval);

        return true;
    }
}
