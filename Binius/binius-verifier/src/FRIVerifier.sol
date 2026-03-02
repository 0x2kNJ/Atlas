// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import {BinaryFieldLib} from "./BinaryFieldLib.sol";
import {MerkleVerifier} from "./MerkleVerifier.sol";
import {FiatShamirTranscript} from "./FiatShamirTranscript.sol";

/// @title FRIVerifier
/// @notice Verifies FRI (Fast Reed-Solomon IOP of Proximity) proofs over binary fields.
///
///   Binius64 uses a binary-field variant of FRI based on the BaseFold construction
///   from [DP24]. The protocol reduces a claimed polynomial commitment to a constant
///   through a sequence of folding rounds.
///
///   Each round:
///     1. Prover commits to the folded polynomial via a Merkle tree
///     2. Verifier samples a random folding challenge α ∈ GF(2^128)
///     3. At query time: verifier checks consistency between adjacent rounds
///        by verifying that the folded evaluation matches the fold formula.
///
///   Binary-field FRI fold formula (BaseFold / [DP24]):
///
///   Unlike prime-field FRI, binary-field FRI uses *additive* evaluation domains
///   (linear subspaces of GF(2^k)), not multiplicative cosets. There is no
///   "division by 2" — characteristic 2 means 2 = 0. Instead:
///
///   For a folding round with challenge α ∈ GF(2^128), given a coset pair
///   (y0, y1) where y0 = f(s) and y1 = f(s ⊕ δ) for subspace shift δ:
///
///     f_folded = y0 + α · (y0 + y1) · inv(δ)
///
///   In this implementation, the evaluation domain is the boolean hypercube
///   {0,1}^n embedded in GF(2^n), normalized so that the subspace shift at
///   each level is δ = 1. Therefore inv(δ) = 1, and the fold simplifies to:
///
///     f_folded = y0 + α · (y0 + y1)     [all arithmetic in GF(2^128)]
///
///   This matches the binius64 Rust crate's `fold` implementation. The
///   sInv = 1 hardcoding in _verifyQueryRound is correct for this domain.
///   Any prover that uses a different domain normalization would need to pass
///   a different sInv; in that case binaryFold(y0, y1, alpha, sInv) handles it.
library FRIVerifier {
    using BinaryFieldLib for uint256;
    using FiatShamirTranscript for FiatShamirTranscript.Transcript;

    struct FRIRoundCommitment {
        bytes32 merkleRoot;
    }

    struct FRIQueryRound {
        uint256 val0;           // evaluation at query index
        uint256 val1;           // evaluation at paired index
        bytes32[] merkleProof0; // proof for val0
        bytes32[] merkleProof1; // proof for val1
    }

    struct FRIQuery {
        uint256 queryIndex;          // the initial query index
        FRIQueryRound[] rounds;      // one per folding round
        uint256 finalValue;          // claimed constant polynomial value
    }

    struct FRIProof {
        FRIRoundCommitment[] commitments; // one Merkle root per folding round
        FRIQuery[] queries;               // multiple queries for soundness
        uint256 finalPoly;                // the final constant value
    }

    struct FRIParams {
        uint256 numFoldingRounds;   // log(n) - log(final_size)
        uint256 numQueries;         // security parameter: number of queries (e.g., 64)
        uint256 logDomainSize;      // log₂ of the initial evaluation domain
    }

    /// @notice Compute the binary-field FRI fold.
    /// @dev Given a coset pair (y0, y1) and folding challenge α, with subspace
    ///      indicator s (used for normalization), compute:
    ///        folded = y0 + α · (y0 + y1) · inv(s)
    ///      All arithmetic in GF(2^128).
    function binaryFold(
        uint256 y0,
        uint256 y1,
        uint256 alpha,
        uint256 sInv
    ) internal pure returns (uint256) {
        uint256 diff = y0 ^ y1;
        uint256 normalizedDiff = BinaryFieldLib.mulGF2_128(diff, sInv);
        uint256 correction = BinaryFieldLib.mulGF2_128(alpha, normalizedDiff);
        return y0 ^ correction;
    }

    /// @notice Verify a complete FRI proof.
    /// @param initialRoot The Merkle root of the initial polynomial commitment
    /// @param proof The FRI proof (commitments, queries, final value)
    /// @param params FRI parameters
    /// @param transcript Fiat-Shamir transcript (should already have context absorbed)
    /// @return valid Whether the FRI proof verifies
    function verify(
        bytes32 initialRoot,
        FRIProof memory proof,
        FRIParams memory params,
        FiatShamirTranscript.Transcript memory transcript
    ) internal pure returns (bool valid) {
        require(
            proof.commitments.length == params.numFoldingRounds,
            "FRI: wrong number of commitments"
        );
        require(
            proof.queries.length == params.numQueries,
            "FRI: wrong number of queries"
        );

        // Phase 1: Absorb all round commitments and sample folding challenges.
        // Transcript ordering (critical for soundness): for each round r,
        //   absorb(commitment[r])  THEN  squeeze(alpha[r]).
        // This ensures alpha[r] is sampled after the prover commits to the
        // round r polynomial, preventing the prover from choosing the commitment
        // to manipulate the challenge. Each absorb() also resets squeezeCounter,
        // so alpha[r] is always derived from a fresh post-commitment state.
        uint256[] memory alphas = new uint256[](params.numFoldingRounds);
        for (uint256 r = 0; r < params.numFoldingRounds; r++) {
            transcript.absorbBytes32(proof.commitments[r].merkleRoot);
            alphas[r] = transcript.squeeze128();
        }

        // Phase 2: Sample query indices
        uint256[] memory queryIndices = new uint256[](params.numQueries);
        uint256 domainSize = 1 << params.logDomainSize;
        for (uint256 q = 0; q < params.numQueries; q++) {
            uint256 raw = transcript.squeeze128();
            queryIndices[q] = raw % domainSize;
        }

        // Phase 3: Verify each query
        for (uint256 q = 0; q < params.numQueries; q++) {
            if (!_verifyQuery(
                initialRoot,
                proof,
                params,
                alphas,
                queryIndices[q],
                proof.queries[q]
            )) {
                return false;
            }
        }

        // Phase 4: Verify all queries agree on the final polynomial value
        for (uint256 q = 0; q < params.numQueries; q++) {
            if (proof.queries[q].finalValue != proof.finalPoly) {
                return false;
            }
        }

        return true;
    }

    /// @dev Verify a single FRI query path across all folding rounds.
    function _verifyQuery(
        bytes32 initialRoot,
        FRIProof memory proof,
        FRIParams memory params,
        uint256[] memory alphas,
        uint256 queryIndex,
        FRIQuery memory query
    ) private pure returns (bool) {
        require(
            query.rounds.length == params.numFoldingRounds,
            "FRI: query round count mismatch"
        );

        uint256 currentIndex = queryIndex;
        uint256 logSize = params.logDomainSize;

        for (uint256 r = 0; r < params.numFoldingRounds; r++) {
            uint256 result = _verifyQueryRound(
                r == 0 ? initialRoot : proof.commitments[r - 1].merkleRoot,
                query.rounds[r],
                alphas[r],
                currentIndex,
                logSize
            );
            // result encodes: high bit = error flag, low bits = folded index
            if (result == type(uint256).max) return false;

            // Last round: check final value
            uint256 foldedIdx = result & ((1 << 128) - 1);
            uint256 folded = result >> 128;
            if (r + 1 == params.numFoldingRounds) {
                if (folded != query.finalValue) return false;
            }

            currentIndex = foldedIdx;
            logSize -= 1;
        }
        return true;
    }

    /// @dev Process a single query round. Returns (folded_value << 128) | folded_index,
    ///      or type(uint256).max on Merkle proof failure.
    function _verifyQueryRound(
        bytes32 root,
        FRIQueryRound memory round,
        uint256 alpha,
        uint256 currentIndex,
        uint256 logSize
    ) private pure returns (uint256) {
        uint256 half = 1 << (logSize - 1);
        uint256 idx0 = currentIndex < half ? currentIndex : currentIndex - half;
        uint256 idx1 = idx0 + half;

        if (!MerkleVerifier.verifyProof(root, MerkleVerifier.hashLeaf(round.val0), idx0, round.merkleProof0)) {
            return type(uint256).max;
        }
        if (!MerkleVerifier.verifyProof(root, MerkleVerifier.hashLeaf(round.val1), idx1, round.merkleProof1)) {
            return type(uint256).max;
        }

        // sInv = 1 because the evaluation domain is normalized so the subspace
        // shift at every folding level is δ = 1 (see library-level comment).
        uint256 folded = binaryFold(round.val0, round.val1, alpha, 1);
        return (folded << 128) | idx0;
    }
}
