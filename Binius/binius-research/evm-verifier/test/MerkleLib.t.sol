// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/lib/MerkleLib.sol";

contract MerkleLibTest is Test {
    // ─── Depth-1 tree (2 leaves) ─────────────────────────────────────────────

    function test_depth1_left() public view {
        bytes32 left = bytes32(uint256(0xAA));
        bytes32 right = bytes32(uint256(0xBB));
        bytes32 root = _sha256pair(left, right);

        bytes32[] memory siblings = new bytes32[](1);
        siblings[0] = right;
        assertTrue(MerkleLib.verify(root, left, siblings, 0), "left leaf at index 0");
    }

    function test_depth1_right() public view {
        bytes32 left = bytes32(uint256(0xAA));
        bytes32 right = bytes32(uint256(0xBB));
        bytes32 root = _sha256pair(left, right);

        bytes32[] memory siblings = new bytes32[](1);
        siblings[0] = left;
        assertTrue(MerkleLib.verify(root, right, siblings, 1), "right leaf at index 1");
    }

    // ─── Depth-2 tree (4 leaves) ─────────────────────────────────────────────

    function test_depth2() public view {
        bytes32 l0 = bytes32(uint256(1));
        bytes32 l1 = bytes32(uint256(2));
        bytes32 l2 = bytes32(uint256(3));
        bytes32 l3 = bytes32(uint256(4));

        bytes32 n01 = _sha256pair(l0, l1);
        bytes32 n23 = _sha256pair(l2, l3);
        bytes32 root = _sha256pair(n01, n23);

        // Verify l0 at index 0: path = [l1, n23]
        bytes32[] memory siblings = new bytes32[](2);
        siblings[0] = l1;
        siblings[1] = n23;
        assertTrue(MerkleLib.verify(root, l0, siblings, 0));

        // Verify l3 at index 3 (binary 11): path = [l2, n01]
        siblings[0] = l2;
        siblings[1] = n01;
        assertTrue(MerkleLib.verify(root, l3, siblings, 3));
    }

    // ─── Wrong proof ─────────────────────────────────────────────────────────

    function test_wrong_leaf_fails() public view {
        bytes32 left = bytes32(uint256(0xAA));
        bytes32 right = bytes32(uint256(0xBB));
        bytes32 root = _sha256pair(left, right);

        bytes32[] memory siblings = new bytes32[](1);
        siblings[0] = right;
        bytes32 wrongLeaf = bytes32(uint256(0xCC));
        assertFalse(MerkleLib.verify(root, wrongLeaf, siblings, 0), "wrong leaf");
    }

    function test_wrong_sibling_fails() public view {
        bytes32 left = bytes32(uint256(0xAA));
        bytes32 right = bytes32(uint256(0xBB));
        bytes32 root = _sha256pair(left, right);

        bytes32[] memory siblings = new bytes32[](1);
        siblings[0] = bytes32(uint256(0xFF));
        assertFalse(MerkleLib.verify(root, left, siblings, 0), "wrong sibling");
    }

    function test_wrong_index_fails() public view {
        bytes32 left = bytes32(uint256(0xAA));
        bytes32 right = bytes32(uint256(0xBB));
        bytes32 root = _sha256pair(left, right);

        bytes32[] memory siblings = new bytes32[](1);
        siblings[0] = right;
        // left is at index 0, but we claim index 1
        assertFalse(MerkleLib.verify(root, left, siblings, 1), "wrong index");
    }

    // ─── verifyOrRevert ──────────────────────────────────────────────────────

    function test_verifyOrRevert_succeeds() public view {
        bytes32 left = bytes32(uint256(0xAA));
        bytes32 right = bytes32(uint256(0xBB));
        bytes32 root = _sha256pair(left, right);

        bytes32[] memory siblings = new bytes32[](1);
        siblings[0] = right;
        MerkleLib.verifyOrRevert(root, left, siblings, 0);
    }

    function test_verifyOrRevert_reverts() public {
        MerkleRevertHelper h = new MerkleRevertHelper();
        vm.expectRevert("MerkleLib: invalid proof");
        h.verifyBad();
    }

    // ─── Deep tree (depth 20) gas benchmark ──────────────────────────────────

    function test_bench_depth20() public {
        bytes32 leaf = bytes32(uint256(0xDEAD));
        bytes32 current = leaf;
        bytes32[] memory siblings = new bytes32[](20);

        for (uint256 i = 0; i < 20; i++) {
            siblings[i] = bytes32(uint256(i + 1));
            current = _sha256pair(current, siblings[i]);
        }

        uint256 g0 = gasleft();
        bool ok = MerkleLib.verify(current, leaf, siblings, 0);
        uint256 g1 = gasleft();
        assertTrue(ok);
        emit log_named_uint("MerkleLib.verify(depth=20) gas", g0 - g1);
    }

    // ─── sha256Single ────────────────────────────────────────────────────────

    function test_sha256Single() public view {
        bytes32 data = bytes32(uint256(42));
        bytes32 h = MerkleLib.sha256Single(data);
        // Should be SHA256 of the 32-byte big-endian encoding of 42
        bytes32 expected = sha256(abi.encodePacked(data));
        assertEq(h, expected);
    }

    // ─── Helper ──────────────────────────────────────────────────────────────

    function _sha256pair(bytes32 a, bytes32 b) internal view returns (bytes32 result) {
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            let ok := staticcall(gas(), 0x02, 0x00, 64, 0x00, 32)
            if iszero(ok) { revert(0, 0) }
            result := mload(0x00)
        }
    }
}

contract MerkleRevertHelper {
    function verifyBad() external view {
        bytes32[] memory siblings = new bytes32[](1);
        siblings[0] = bytes32(uint256(0xBB));
        MerkleLib.verifyOrRevert(
            bytes32(uint256(0xFF)), // wrong root
            bytes32(uint256(0xAA)),
            siblings,
            0
        );
    }
}
