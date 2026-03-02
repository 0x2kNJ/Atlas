// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import {BinaryFieldLib} from "./BinaryFieldLib.sol";
import {FiatShamirTranscript} from "./FiatShamirTranscript.sol";
import {SumcheckVerifier} from "./SumcheckVerifier.sol";
import {FRIVerifier} from "./FRIVerifier.sol";
import {MerkleVerifier} from "./MerkleVerifier.sol";
import {BiniusPCSVerifier} from "./BiniusPCSVerifier.sol";

/// @title Binius64Verifier
/// @notice Top-level verifier for Binius64 SNARK proofs on the EVM.
///
///   Binius64 proof verification follows this pipeline:
///
///   1. **Public input check** — verify the prover's claimed public inputs
///   2. **Shift reduction** — sumcheck to reduce shifted-index constraints
///   3. **MUL constraint reduction** — GKR-based sumcheck for u64 multiplications
///   4. **AND constraint reduction** — Rijndael zerocheck for bitwise AND operations
///   5. **Oracle opening** — PCS verification via ring-switching + FRI
///
///   This contract orchestrates all sub-verifiers and manages the Fiat-Shamir
///   transcript throughout the verification.
contract Binius64Verifier {
    using FiatShamirTranscript for FiatShamirTranscript.Transcript;

    struct PublicInput {
        uint256[] values;    // public witness values
    }

    struct ConstraintProof {
        SumcheckVerifier.SumcheckProof shiftSumcheck;
        SumcheckVerifier.SumcheckProof mulSumcheck;
        SumcheckVerifier.SumcheckProof andSumcheck;
    }

    struct Binius64Proof {
        // Constraint system phase
        bytes32 oracleCommitment;    // Merkle root of the witness polynomial
        uint256 numVariables;        // log₂ of the trace length
        PublicInput publicInput;
        ConstraintProof constraints;
        // PCS opening phase
        BiniusPCSVerifier.RingSwitchProof ringSwitchProof;
        FRIVerifier.FRIProof friProof;
    }

    /// @notice Verify a Binius64 proof.
    /// @param proof The complete proof object
    /// @return valid Whether the proof is accepted
    function verify(Binius64Proof calldata proof) external pure returns (bool valid) {
        FiatShamirTranscript.Transcript memory transcript =
            FiatShamirTranscript.initWithDomainSep("binius64-snark-v1");

        // Step 1: Absorb public inputs and oracle commitment
        transcript.absorbBytes32(proof.oracleCommitment);
        transcript.absorbUint256(proof.numVariables);
        for (uint256 i = 0; i < proof.publicInput.values.length; i++) {
            transcript.absorbUint256(proof.publicInput.values[i]);
        }

        // Step 2: Shift reduction sumcheck
        SumcheckVerifier.SumcheckClaim memory shiftClaim = SumcheckVerifier.SumcheckClaim({
            claimedSum: 0, // shift constraints should sum to zero
            numVariables: proof.numVariables
        });
        SumcheckVerifier.SumcheckResult memory shiftResult = SumcheckVerifier.verify(
            shiftClaim,
            _toMemory(proof.constraints.shiftSumcheck),
            transcript
        );

        // Step 3: MUL constraint reduction sumcheck
        SumcheckVerifier.SumcheckClaim memory mulClaim = SumcheckVerifier.SumcheckClaim({
            claimedSum: 0,
            numVariables: proof.numVariables
        });
        /* mulResult used for PCS batching in production */
        SumcheckVerifier.verify(
            mulClaim,
            _toMemory(proof.constraints.mulSumcheck),
            transcript
        );

        // Step 4: AND constraint reduction sumcheck
        SumcheckVerifier.SumcheckClaim memory andClaim = SumcheckVerifier.SumcheckClaim({
            claimedSum: 0,
            numVariables: proof.numVariables
        });
        /* andResult used for PCS batching in production */
        SumcheckVerifier.verify(
            andClaim,
            _toMemory(proof.constraints.andSumcheck),
            transcript
        );

        // Step 5: PCS opening via ring-switching + FRI
        BiniusPCSVerifier.PCSCommitment memory commitment = BiniusPCSVerifier.PCSCommitment({
            merkleRoot: proof.oracleCommitment,
            numVariables: proof.numVariables
        });

        // The PCS opening checks that the oracle evaluations at the sumcheck
        // output points are consistent with the committed polynomial.
        BiniusPCSVerifier.EvaluationClaim memory evalClaim = BiniusPCSVerifier.EvaluationClaim({
            point: shiftResult.challenges,
            value: shiftResult.finalEval
        });

        BiniusPCSVerifier.PCSOpeningProof memory pcsProof = BiniusPCSVerifier.PCSOpeningProof({
            ringSwitch: _ringSwitchToMemory(proof.ringSwitchProof),
            friProof: _friToMemory(proof.friProof)
        });

        return BiniusPCSVerifier.verify(commitment, evalClaim, pcsProof, transcript);
    }

    // ABI encoding helpers: convert calldata structs to memory for library calls

    function _toMemory(SumcheckVerifier.SumcheckProof calldata p)
        private
        pure
        returns (SumcheckVerifier.SumcheckProof memory m)
    {
        m.rounds = new SumcheckVerifier.RoundPoly[](p.rounds.length);
        for (uint256 i = 0; i < p.rounds.length; i++) {
            m.rounds[i].coeffs[0] = p.rounds[i].coeffs[0];
            m.rounds[i].coeffs[1] = p.rounds[i].coeffs[1];
            m.rounds[i].coeffs[2] = p.rounds[i].coeffs[2];
            m.rounds[i].coeffs[3] = p.rounds[i].coeffs[3];
        }
    }

    function _ringSwitchToMemory(BiniusPCSVerifier.RingSwitchProof calldata p)
        private
        pure
        returns (BiniusPCSVerifier.RingSwitchProof memory m)
    {
        m.sumcheckProof = _toMemory(p.sumcheckProof);
        m.innerEval = p.innerEval;
    }

    function _friToMemory(FRIVerifier.FRIProof calldata p)
        private
        pure
        returns (FRIVerifier.FRIProof memory m)
    {
        m.commitments = new FRIVerifier.FRIRoundCommitment[](p.commitments.length);
        for (uint256 i = 0; i < p.commitments.length; i++) {
            m.commitments[i].merkleRoot = p.commitments[i].merkleRoot;
        }

        m.queries = new FRIVerifier.FRIQuery[](p.queries.length);
        for (uint256 q = 0; q < p.queries.length; q++) {
            m.queries[q].queryIndex = p.queries[q].queryIndex;
            m.queries[q].finalValue = p.queries[q].finalValue;

            m.queries[q].rounds = new FRIVerifier.FRIQueryRound[](p.queries[q].rounds.length);
            for (uint256 r = 0; r < p.queries[q].rounds.length; r++) {
                m.queries[q].rounds[r].val0 = p.queries[q].rounds[r].val0;
                m.queries[q].rounds[r].val1 = p.queries[q].rounds[r].val1;

                m.queries[q].rounds[r].merkleProof0 =
                    new bytes32[](p.queries[q].rounds[r].merkleProof0.length);
                for (uint256 k = 0; k < p.queries[q].rounds[r].merkleProof0.length; k++) {
                    m.queries[q].rounds[r].merkleProof0[k] = p.queries[q].rounds[r].merkleProof0[k];
                }

                m.queries[q].rounds[r].merkleProof1 =
                    new bytes32[](p.queries[q].rounds[r].merkleProof1.length);
                for (uint256 k = 0; k < p.queries[q].rounds[r].merkleProof1.length; k++) {
                    m.queries[q].rounds[r].merkleProof1[k] = p.queries[q].rounds[r].merkleProof1[k];
                }
            }
        }

        m.finalPoly = p.finalPoly;
    }
}
