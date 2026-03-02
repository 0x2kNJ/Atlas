// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/BinaryFieldLib.sol";
import "../src/BinaryFieldLibOpt.sol";

/// @notice Computes the Zech log/exp tables for GF(2^8) in the Binius tower.
///         Run `forge test --match-test test_print_solidity_constants -vvvv`
///         to capture the EXP_TABLE and LOG_TABLE hex for hard-coding.
contract GenTablesTest is Test {

    function test_print_solidity_constants() public {
        uint256 g = _findGenerator();
        emit log_named_uint("GF256 primitive generator", g);

        bytes memory expOut = new bytes(256);
        bytes memory logOut = new bytes(256);

        // Build exp[] and log[]
        // exp[i] = g^i for i in 0..254, exp[255] = exp[0] = 1
        // log[0] = 0xFF (sentinel for zero element)
        uint256 cur = 1;
        for (uint256 i = 0; i < 255; i++) {
            expOut[i] = bytes1(uint8(cur));
            logOut[cur] = bytes1(uint8(i));
            cur = BinaryFieldLib.mulGF256(cur, g);
        }
        expOut[255] = bytes1(uint8(1)); // exp[255] = g^255 = 1
        logOut[0] = bytes1(uint8(0xFF)); // sentinel: log(0) is undefined

        emit log_named_bytes("EXP_TABLE", expOut);
        emit log_named_bytes("LOG_TABLE", logOut);
    }

    function test_verify_tables_consistency() public {
        uint256 g = _findGenerator();
        bytes memory expOut = new bytes(256);
        bytes memory logOut = new bytes(256);

        uint256 cur = 1;
        for (uint256 i = 0; i < 255; i++) {
            expOut[i] = bytes1(uint8(cur));
            logOut[cur] = bytes1(uint8(i));
            cur = BinaryFieldLib.mulGF256(cur, g);
        }
        expOut[255] = bytes1(uint8(1));
        logOut[0] = bytes1(uint8(0xFF));

        uint256 failures = 0;
        for (uint256 a = 1; a < 256; a++) {
            for (uint256 b = 1; b < 256; b++) {
                uint256 expected = BinaryFieldLib.mulGF256(a, b);
                uint256 la = uint8(logOut[a]);
                uint256 lb = uint8(logOut[b]);
                uint256 logSum = (la + lb) % 255;
                uint256 got = uint8(expOut[logSum]);
                if (got != expected) {
                    failures++;
                    if (failures <= 5) {
                        emit log_named_uint("mismatch a", a);
                        emit log_named_uint("mismatch b", b);
                        emit log_named_uint("expected", expected);
                        emit log_named_uint("got", got);
                    }
                }
            }
        }
        assertEq(failures, 0, "table lookup disagrees with recursive mul");
        emit log_named_uint("All pairs correct", 255 * 255);
    }

    // -----------------------------------------------------------------------
    //  CI guard: hardcoded tables in BinaryFieldLibOpt must match computed tables
    //
    //  This test ensures that any future change to BinaryFieldLib that fixes a
    //  field arithmetic bug is automatically reflected as a failure here, forcing
    //  the developer to regenerate the Zech log tables (via test_print_solidity_constants)
    //  and update BinaryFieldLibOpt. Without this test, a BinaryFieldLib fix would
    //  leave BinaryFieldLibOpt silently computing wrong results.
    // -----------------------------------------------------------------------

    function test_hardcoded_tables_match_computed() public {
        uint256 g = 19; // generator used in BinaryFieldLibOpt

        // Compute tables from scratch using BinaryFieldLib
        bytes memory expComputed = new bytes(256);
        bytes memory logComputed = new bytes(256);

        uint256 cur = 1;
        for (uint256 i = 0; i < 255; i++) {
            expComputed[i] = bytes1(uint8(cur));
            logComputed[cur] = bytes1(uint8(i));
            cur = BinaryFieldLib.mulGF256(cur, g);
        }
        expComputed[255] = bytes1(uint8(1));
        logComputed[0] = bytes1(uint8(0xFF));

        // Compare against the hardcoded constants in BinaryFieldLibOpt
        bytes memory expHardcoded = BinaryFieldLibOpt.EXP_TABLE;
        bytes memory logHardcoded = BinaryFieldLibOpt.LOG_TABLE;

        uint256 expFailures = 0;
        uint256 logFailures = 0;

        for (uint256 i = 0; i < 256; i++) {
            if (expComputed[i] != expHardcoded[i]) {
                expFailures++;
                if (expFailures <= 3) {
                    emit log_named_uint("EXP_TABLE mismatch at index", i);
                    emit log_named_uint("  computed", uint8(expComputed[i]));
                    emit log_named_uint("  hardcoded", uint8(expHardcoded[i]));
                }
            }
            if (logComputed[i] != logHardcoded[i]) {
                logFailures++;
                if (logFailures <= 3) {
                    emit log_named_uint("LOG_TABLE mismatch at index", i);
                    emit log_named_uint("  computed", uint8(logComputed[i]));
                    emit log_named_uint("  hardcoded", uint8(logHardcoded[i]));
                }
            }
        }

        assertEq(expFailures, 0, "EXP_TABLE hardcoded in BinaryFieldLibOpt does not match computed table");
        assertEq(logFailures, 0, "LOG_TABLE hardcoded in BinaryFieldLibOpt does not match computed table");
    }

    // -----------------------------------------------------------------------

    /// @dev Find smallest primitive element (generator) of GF(2^8)*.
    ///      g is a generator iff g^k != 1 for all k in 1..254.
    function _findGenerator() internal returns (uint256) {
        for (uint256 g = 2; g < 256; g++) {
            if (_order255(g)) return g;
        }
        revert("no generator found");
    }

    /// @dev Returns true iff the element g has multiplicative order exactly 255.
    function _order255(uint256 g) internal returns (bool) {
        uint256 cur = 1;
        for (uint256 i = 1; i <= 254; i++) {
            cur = BinaryFieldLib.mulGF256(cur, g);
            if (cur == 1) return false; // order divides i < 255
        }
        return true; // g^254 != 1 and g^255 = 1 always
    }
}
