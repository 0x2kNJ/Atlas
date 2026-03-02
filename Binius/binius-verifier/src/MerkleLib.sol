// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

/// @title MerkleLib — SHA256 binary Merkle tree verification
/// @notice Verifies inclusion proofs for binary Merkle trees using the SHA256 precompile.
///         This matches the binius64 `BinaryMerkleTreeScheme` where:
///           parent = SHA256(left_child || right_child)
///         Leaf hashing is NOT applied here — the caller provides the pre-hashed leaf digest.
///
///         The `index` uses standard binary path encoding: bit i of index determines
///         whether the node is a left child (0) or right child (1) at depth i.
library MerkleLib {
    /// @notice Verify a Merkle inclusion proof.
    /// @param root     Expected Merkle root.
    /// @param leaf     Leaf digest (already hashed by the caller).
    /// @param siblings Array of sibling digests, from leaf level to root level.
    /// @param index    Position of the leaf (binary path encoding).
    /// @return valid   True if the proof is valid.
    function verify(
        bytes32 root,
        bytes32 leaf,
        bytes32[] memory siblings,
        uint256 index
    ) internal view returns (bool valid) {
        bytes32 current = leaf;
        for (uint256 i = 0; i < siblings.length; i++) {
            if (index & 1 == 0) {
                current = _sha256pair(current, siblings[i]);
            } else {
                current = _sha256pair(siblings[i], current);
            }
            index >>= 1;
        }
        valid = (current == root);
    }

    /// @notice Verify a Merkle proof and revert if invalid.
    function verifyOrRevert(
        bytes32 root,
        bytes32 leaf,
        bytes32[] memory siblings,
        uint256 index
    ) internal view {
        require(verify(root, leaf, siblings, index), "MerkleLib: invalid proof");
    }

    /// @notice SHA256(left || right) using the precompile at 0x02.
    function _sha256pair(bytes32 left, bytes32 right) private view returns (bytes32 result) {
        assembly {
            mstore(0x00, left)
            mstore(0x20, right)
            let ok := staticcall(gas(), 0x02, 0x00, 64, 0x00, 32)
            if iszero(ok) { revert(0, 0) }
            result := mload(0x00)
        }
    }

    /// @notice Compute SHA256(data) for a single 32-byte input (leaf hashing).
    function sha256Single(bytes32 data) internal view returns (bytes32 result) {
        assembly {
            mstore(0x00, data)
            let ok := staticcall(gas(), 0x02, 0x00, 32, 0x00, 32)
            if iszero(ok) { revert(0, 0) }
            result := mload(0x00)
        }
    }
}
