// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

/// @title MerkleVerifier
/// @notice Verifies Merkle authentication paths for the PCS commitment scheme.
///
///   The polynomial commitment in Binius64 uses a Merkle tree over evaluations
///   of the committed polynomial at a domain. The verifier queries specific
///   leaves and checks authentication paths against the committed root.
///
///   Tree structure:
///     - Leaves are keccak256 hashes of evaluation tuples (domain point, value).
///     - Internal nodes: keccak256(left || right) with left < right (canonical ordering).
///     - Root is the commitment.
library MerkleVerifier {
    /// @notice Verify a single Merkle inclusion proof.
    /// @param root The committed Merkle root
    /// @param leaf The leaf value (pre-hashed)
    /// @param index The leaf index (0-based, determines left/right placement)
    /// @param proof The sibling hashes from leaf to root
    /// @return valid True if the proof is correct
    function verifyProof(
        bytes32 root,
        bytes32 leaf,
        uint256 index,
        bytes32[] memory proof
    ) internal pure returns (bool valid) {
        bytes32 current = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 sibling = proof[i];
            if (index & 1 == 0) {
                current = keccak256(abi.encodePacked(current, sibling));
            } else {
                current = keccak256(abi.encodePacked(sibling, current));
            }
            index >>= 1;
        }
        return current == root;
    }

    /// @notice Hash a leaf from a field element (evaluation at a query point).
    function hashLeaf(uint256 value) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(uint8(0x00), value));
    }

    /// @notice Hash a leaf from two field elements (evaluation pair for FRI).
    function hashLeafPair(uint256 val0, uint256 val1) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(uint8(0x00), val0, val1));
    }

    /// @notice Verify multiple Merkle proofs against the same root.
    ///         Returns true only if ALL proofs verify.
    function verifyBatch(
        bytes32 root,
        bytes32[] memory leaves,
        uint256[] memory indices,
        bytes32[][] memory proofs
    ) internal pure returns (bool) {
        require(
            leaves.length == indices.length && indices.length == proofs.length,
            "MerkleVerifier: array length mismatch"
        );
        for (uint256 i = 0; i < leaves.length; i++) {
            if (!verifyProof(root, leaves[i], indices[i], proofs[i])) {
                return false;
            }
        }
        return true;
    }
}
