// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/lib/Transcript.sol";

contract TranscriptTest is Test {
    using Transcript for Transcript.State;

    function test_init() public pure {
        bytes memory proof = hex"DEADBEEF";
        Transcript.State memory t = Transcript.init(proof);
        assertEq(t.offset, 0);
        assertFalse(t.isObserver, "starts in sampler mode");
    }

    function test_observe_deterministic() public view {
        Transcript.State memory t1 = Transcript.init(hex"");
        Transcript.State memory t2 = Transcript.init(hex"");
        t1.observe(hex"AABBCCDD");
        t2.observe(hex"AABBCCDD");
        // Sample from both and compare
        uint256 c1 = t1.sampleGF128();
        uint256 c2 = t2.sampleGF128();
        assertEq(c1, c2, "same input => same challenge");
    }

    function test_observe_different_data() public view {
        Transcript.State memory t1 = Transcript.init(hex"");
        Transcript.State memory t2 = Transcript.init(hex"");
        t1.observe(hex"AA");
        t2.observe(hex"BB");
        uint256 c1 = t1.sampleGF128();
        uint256 c2 = t2.sampleGF128();
        assertTrue(c1 != c2, "different input => different challenge");
    }

    function test_sampleGF128_in_range() public view {
        Transcript.State memory t = Transcript.init(hex"");
        t.observe(hex"DEADBEEF");
        uint256 ch = t.sampleGF128();
        assertTrue(ch < (uint256(1) << 128), "challenge fits in 128 bits");
    }

    function test_two_challenges_differ() public view {
        Transcript.State memory t = Transcript.init(hex"");
        t.observe(hex"DEADBEEF");
        uint256 ch1 = t.sampleGF128();
        uint256 ch2 = t.sampleGF128();
        assertTrue(ch1 != ch2, "consecutive challenges should differ");
    }

    function test_messageGF128() public view {
        // 16 bytes of LE data: value = 0x100F0E0D0C0B0A090807060504030201
        bytes memory proof = hex"0102030405060708090A0B0C0D0E0F10";
        Transcript.State memory t = Transcript.init(proof);
        uint256 val = t.messageGF128();
        // LE interpretation: byte[0]=0x01 is LSB, byte[15]=0x10 is MSB
        assertEq(val, 0x100F0E0D0C0B0A090807060504030201, "LE u128 parse");
        assertEq(t.offset, 16);
    }

    function test_messageBytes32() public view {
        bytes memory proof = hex"0102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20";
        Transcript.State memory t = Transcript.init(proof);
        bytes32 val = t.messageBytes32();
        assertEq(val, bytes32(hex"0102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20"));
        assertEq(t.offset, 32);
    }

    function test_messageGF128_twice() public view {
        bytes memory proof = hex"0102030405060708090A0B0C0D0E0F10AABBCCDDEEFF00112233445566778899";
        Transcript.State memory t = Transcript.init(proof);
        uint256 v1 = t.messageGF128();
        uint256 v2 = t.messageGF128();
        assertEq(v1, 0x100F0E0D0C0B0A090807060504030201);
        assertEq(v2, 0x99887766554433221100FFEEDDCCBBAA);
        assertEq(t.offset, 32);
    }

    function test_readPastEnd_reverts() public {
        TranscriptRevertHelper h = new TranscriptRevertHelper();
        vm.expectRevert("Transcript: read past end");
        h.readGF128Short();
    }

    function test_finalize_success() public view {
        bytes memory proof = hex"0102030405060708090A0B0C0D0E0F10";
        Transcript.State memory t = Transcript.init(proof);
        t.messageGF128();
        t.finalize();
    }

    function test_finalize_fail() public {
        TranscriptRevertHelper h = new TranscriptRevertHelper();
        vm.expectRevert("Transcript: unconsumed proof bytes");
        h.finalizeEarly();
    }

    function test_readRaw() public view {
        bytes memory proof = hex"AABBCCDD";
        Transcript.State memory t = Transcript.init(proof);
        bytes memory data = t.readRaw(4);
        assertEq(data.length, 4);
        assertEq(t.offset, 4);
    }

    function test_challengeBytes32() public view {
        Transcript.State memory t = Transcript.init(hex"");
        t.observe(hex"FF");
        bytes32 ch = t.challengeBytes32();
        assertTrue(ch != bytes32(0));
    }

    // Legacy API tests
    function test_legacy_readGF128() public view {
        bytes memory proof = hex"0102030405060708090A0B0C0D0E0F10";
        Transcript.State memory t = Transcript.init(proof);
        uint256 val = t.readGF128();
        assertEq(val, 0x100F0E0D0C0B0A090807060504030201);
    }

    function test_legacy_challengeGF128() public view {
        Transcript.State memory t = Transcript.init(hex"");
        t.observe(hex"DEADBEEF");
        uint256 ch = t.challengeGF128();
        assertTrue(ch != 0);
        assertTrue(ch < (uint256(1) << 128));
    }

    function test_fiat_shamir_matches_rust_init() public view {
        // Verify initial state: SHA256("") = e3b0c442...
        Transcript.State memory t = Transcript.init(hex"");
        // The sampler buffer should be SHA256("")
        assertEq(
            t.samplerBuffer,
            hex"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        // First 8 bytes of sampling should match SHA256("")[0..8]
        bytes memory first8 = t.sampleBytes(8);
        assertEq(first8[0], hex"e3");
        assertEq(first8[1], hex"b0");
    }

    // ─── Cross-reference tests with Rust HasherChallenger ───────────────────

    function test_rust_vector_1_initial_sample() public view {
        Transcript.State memory t = Transcript.init(hex"");
        uint256 ch = t.sampleGF128();
        assertEq(ch, 0x24b96f99c8f4fb9a141cfc9842c4b0e3, "Rust vector 1: initial sample");
    }

    function test_rust_vector_2_observe_then_sample() public view {
        Transcript.State memory t = Transcript.init(hex"");
        t.observe(hex"DEADBEEFCAFEBABE");
        uint256 ch = t.sampleGF128();
        assertEq(ch, 0xc7cf92ac74b136bb2c1fde0e24bbcbbb, "Rust vector 2: observe then sample");
    }

    function test_rust_vector_3_message_then_sample() public view {
        Transcript.State memory t = Transcript.init(hex"0102030405060708090A0B0C0D0E0F10");
        uint256 msg = t.messageGF128();
        assertEq(msg, 0x100f0e0d0c0b0a090807060504030201, "msg parse");
        uint256 ch = t.sampleGF128();
        assertEq(ch, 0xf2131a1e14b79b441ad8e82af91b3c18, "Rust vector 3: message then sample");
    }

    function test_rust_vector_5_multiple_cycles() public view {
        Transcript.State memory t = Transcript.init(hex"");
        t.observe(hex"1111111111111111");
        uint256 s1 = t.sampleGF128();
        assertEq(s1, 0x1a37494370eb68201e7749b7faad3737, "Rust vector 5 cycle 1");
        t.observe(hex"2222222222222222");
        uint256 s2 = t.sampleGF128();
        assertEq(s2, 0x1ad20a723b213497efe677e9ce6e930a, "Rust vector 5 cycle 2");
    }

    function test_rust_vector_6_double_sample() public view {
        Transcript.State memory t = Transcript.init(hex"");
        t.observe(hex"FFFFFFFF");
        uint256 s1 = t.sampleGF128();
        assertEq(s1, 0xea0608691651cb1bede3d0b37be7f379, "Rust vector 6 sample 1");
        uint256 s2 = t.sampleGF128();
        assertEq(s2, 0xd09d422bb1b0e5fce77f11f1df5de4b5, "Rust vector 6 sample 2");
    }

    function test_bench_observe() public {
        Transcript.State memory t = Transcript.init(hex"");
        uint256 g0 = gasleft();
        t.observe(hex"DEADBEEFCAFEBABE");
        uint256 g1 = gasleft();
        emit log_named_uint("Transcript.observe(8 bytes) gas", g0 - g1);
    }
}

contract TranscriptRevertHelper {
    using Transcript for Transcript.State;

    function readGF128Short() external pure {
        bytes memory proof = hex"0102030405060708";
        Transcript.State memory t = Transcript.init(proof);
        t.messageGF128();
    }

    function finalizeEarly() external view {
        bytes memory proof = hex"0102030405060708090A0B0C0D0E0F1011";
        Transcript.State memory t = Transcript.init(proof);
        t.messageGF128();
        t.finalize();
    }
}
