// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/BinaryFieldLib.sol";
import "../src/MerkleVerifier.sol";
import "../src/FRIVerifier.sol";
import "../src/FiatShamirTranscript.sol";

contract MerkleVerifierTest is Test {
    function test_merkle_verify_depth1() public pure {
        // Tree: root = H(leaf0 || leaf1)
        bytes32 leaf0 = MerkleVerifier.hashLeaf(42);
        bytes32 leaf1 = MerkleVerifier.hashLeaf(99);
        bytes32 root = keccak256(abi.encodePacked(leaf0, leaf1));

        // Verify leaf0 at index 0 with proof [leaf1]
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf1;
        assertTrue(MerkleVerifier.verifyProof(root, leaf0, 0, proof), "Leaf0 should verify");

        // Verify leaf1 at index 1 with proof [leaf0]
        proof[0] = leaf0;
        assertTrue(MerkleVerifier.verifyProof(root, leaf1, 1, proof), "Leaf1 should verify");
    }

    function test_merkle_verify_depth2() public pure {
        bytes32 l0 = MerkleVerifier.hashLeaf(10);
        bytes32 l1 = MerkleVerifier.hashLeaf(20);
        bytes32 l2 = MerkleVerifier.hashLeaf(30);
        bytes32 l3 = MerkleVerifier.hashLeaf(40);

        bytes32 n01 = keccak256(abi.encodePacked(l0, l1));
        bytes32 n23 = keccak256(abi.encodePacked(l2, l3));
        bytes32 root = keccak256(abi.encodePacked(n01, n23));

        // Verify l2 at index 2 with proof [l3, n01]
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = l3;
        proof[1] = n01;
        assertTrue(MerkleVerifier.verifyProof(root, l2, 2, proof), "l2 should verify");
    }

    function test_merkle_wrong_leaf_fails() public pure {
        bytes32 leaf0 = MerkleVerifier.hashLeaf(42);
        bytes32 leaf1 = MerkleVerifier.hashLeaf(99);
        bytes32 root = keccak256(abi.encodePacked(leaf0, leaf1));

        bytes32 wrongLeaf = MerkleVerifier.hashLeaf(100);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf1;
        assertFalse(MerkleVerifier.verifyProof(root, wrongLeaf, 0, proof), "Wrong leaf should fail");
    }

    function test_merkle_batch_verify() public pure {
        bytes32 l0 = MerkleVerifier.hashLeaf(10);
        bytes32 l1 = MerkleVerifier.hashLeaf(20);
        bytes32 root = keccak256(abi.encodePacked(l0, l1));

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = l0;
        leaves[1] = l1;

        uint256[] memory indices = new uint256[](2);
        indices[0] = 0;
        indices[1] = 1;

        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = l1;
        proofs[1] = new bytes32[](1);
        proofs[1][0] = l0;

        assertTrue(MerkleVerifier.verifyBatch(root, leaves, indices, proofs), "Batch should verify");
    }

    function test_gas_merkle_verify_depth20() public {
        // Simulate a depth-20 Merkle proof (realistic for 2^20 leaves)
        bytes32 current = MerkleVerifier.hashLeaf(12345);
        bytes32[] memory proof = new bytes32[](20);

        for (uint256 i = 0; i < 20; i++) {
            proof[i] = keccak256(abi.encodePacked("sibling", i));
            current = keccak256(abi.encodePacked(current, proof[i]));
        }

        bytes32 root = current;

        // Rebuild leaf and verify
        bytes32 leaf = MerkleVerifier.hashLeaf(12345);
        uint256 g = gasleft();
        MerkleVerifier.verifyProof(root, leaf, 0, proof);
        uint256 cost = g - gasleft();
        emit log_named_uint("Gas: merkle_verify_depth20", cost);
    }
}

contract FRIVerifierTest is Test {
    function test_binary_fold_zero_alpha() public pure {
        // With alpha = 0: fold(y0, y1, 0, sInv) = y0
        uint256 y0 = 0x42;
        uint256 y1 = 0xFF;
        uint256 result = FRIVerifier.binaryFold(y0, y1, 0, 1);
        assertEq(result, y0, "fold with alpha=0 should return y0");
    }

    function test_binary_fold_identical_values() public pure {
        // When y0 == y1: diff = 0, so fold = y0
        uint256 y = 0x123;
        uint256 result = FRIVerifier.binaryFold(y, y, 0xABCD, 1);
        assertEq(result, y, "fold of identical values should return the value");
    }

    function test_binary_fold_basic() public pure {
        // fold(y0, y1, α, 1) = y0 + α*(y0+y1)
        uint256 y0 = 1;
        uint256 y1 = 0;
        uint256 alpha = 1;
        // fold = 1 + 1*(1+0) = 1 + 1 = 0 (in char 2)
        uint256 result = FRIVerifier.binaryFold(y0, y1, alpha, 1);
        assertEq(result, 0, "fold(1,0,1,1) = 0 in binary field");
    }

    function test_gas_binary_fold() public {
        uint256 y0 = 0x0123456789ABCDEF0123456789ABCDEF;
        uint256 y1 = 0xFEDCBA9876543210FEDCBA9876543210;
        uint256 alpha = 0xDEADBEEFCAFEBABE1234567890ABCDEF;
        uint256 sInv = 0x1111111111111111;

        uint256 g = gasleft();
        FRIVerifier.binaryFold(y0, y1, alpha, sInv);
        uint256 cost = g - gasleft();
        emit log_named_uint("Gas: binary_fold_128bit", cost);
    }
}
