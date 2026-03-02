// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/CLMULPrecompile.sol";
import "../src/BinaryFieldLibOpt.sol";
import "../src/BinaryFieldLib.sol";

/// @title CLMULPrecompile tests
/// @notice Tests the CLMULRouter library under two conditions:
///   1. Software fallback path: nothing deployed at CLMUL_PRECOMPILE_ADDRESS
///   2. Native path: CLMULSoftware deployed at CLMUL_PRECOMPILE_ADDRESS via vm.etch
///
/// Also tests CLMULSoftware as an external contract, verifying it matches
/// BinaryFieldLibOpt results.
contract CLMULPrecompileTest is Test {

    uint256 public a = 0x0123456789ABCDEF0123456789ABCDEF;
    uint256 public b = 0xFEDCBA9876543210FEDCBA9876543210;

    function setUp() public {
        a = uint256(keccak256("clmul_a")) & ((1 << 128) - 1);
        b = uint256(keccak256("clmul_b")) & ((1 << 128) - 1);
    }

    // -----------------------------------------------------------------------
    // Software fallback path (nothing at 0xA0)
    // -----------------------------------------------------------------------

    function test_fallback_mulGF2_128_matches_opt() public view {
        // Nothing is deployed at CLMUL_PRECOMPILE_ADDRESS — CLMULRouter
        // should fall back to BinaryFieldLibOpt.
        uint256 expected = BinaryFieldLibOpt.mulGF2_128(a, b);
        uint256 result   = CLMULRouter.mulGF2_128(a, b);
        assertEq(result, expected, "fallback mul must match BinaryFieldLibOpt");
    }

    function test_fallback_squareGF2_128_matches_opt() public view {
        uint256 expected = BinaryFieldLibOpt.squareGF2_128(a);
        uint256 result   = CLMULRouter.squareGF2_128(a);
        assertEq(result, expected, "fallback square must match BinaryFieldLibOpt");
    }

    function test_fallback_batchInvert_matches_individual() public view {
        uint256[] memory inputs = new uint256[](4);
        inputs[0] = a;
        inputs[1] = b;
        inputs[2] = uint256(keccak256("c")) & ((1 << 128) - 1);
        inputs[3] = uint256(keccak256("d")) & ((1 << 128) - 1);

        // Ensure no zeros (inversion of 0 is 0 in GF(2^128), but skip for clean test)
        for (uint256 i = 0; i < inputs.length; i++) {
            if (inputs[i] == 0) inputs[i] = 1;
        }

        uint256[] memory results = new uint256[](4);
        CLMULRouter.batchInvertGF2_128(inputs, results);

        // Check each result matches individual inversion
        for (uint256 i = 0; i < inputs.length; i++) {
            uint256 expected = BinaryFieldLib.invGF2_128(inputs[i]);
            assertEq(results[i], expected, "batch invert[i] must match individual invGF2_128");
        }
    }

    // -----------------------------------------------------------------------
    // Native path (CLMULSoftware etched at precompile address)
    // -----------------------------------------------------------------------

    function test_native_path_mul_matches_fallback() public {
        // Deploy CLMULSoftware bytecode at the reserved precompile address
        CLMULSoftware sw = new CLMULSoftware();
        bytes memory code = address(sw).code;
        vm.etch(CLMUL_PRECOMPILE_ADDRESS, code);

        uint256 fallbackResult = BinaryFieldLibOpt.mulGF2_128(a, b);
        uint256 native = CLMULRouter.mulGF2_128(a, b);
        assertEq(native, fallbackResult, "native path must match software fallback");
    }

    function test_native_path_square_matches_fallback() public {
        CLMULSoftware sw = new CLMULSoftware();
        vm.etch(CLMUL_PRECOMPILE_ADDRESS, address(sw).code);

        uint256 fallbackResult = BinaryFieldLibOpt.squareGF2_128(a);
        uint256 native = CLMULRouter.squareGF2_128(a);
        assertEq(native, fallbackResult, "native square must match fallback");
    }

    function test_native_path_batch_invert_matches_fallback() public {
        CLMULSoftware sw = new CLMULSoftware();
        vm.etch(CLMUL_PRECOMPILE_ADDRESS, address(sw).code);

        uint256[] memory inputs  = new uint256[](3);
        inputs[0] = a | 1; inputs[1] = b | 1;
        inputs[2] = uint256(keccak256("e")) & ((1 << 128) - 1) | 1;

        uint256[] memory resultsNative   = new uint256[](3);
        uint256[] memory resultsFallback = new uint256[](3);

        CLMULRouter.batchInvertGF2_128(inputs, resultsNative);

        // Revert the etch so fallback path is used
        vm.etch(CLMUL_PRECOMPILE_ADDRESS, bytes(""));
        CLMULRouter.batchInvertGF2_128(inputs, resultsFallback);

        for (uint256 i = 0; i < inputs.length; i++) {
            assertEq(resultsNative[i], resultsFallback[i], "batch invert native vs fallback");
        }
    }

    // -----------------------------------------------------------------------
    // CLMULSoftware external contract — independent correctness checks
    // -----------------------------------------------------------------------

    function test_clmul_software_mul_matches_opt() public {
        CLMULSoftware sw = new CLMULSoftware();
        uint256 expected = BinaryFieldLibOpt.mulGF2_128(a, b);
        uint256 result   = sw.mulGF2_128(a, b);
        assertEq(result, expected, "CLMULSoftware.mulGF2_128 must match BinaryFieldLibOpt");
    }

    function test_clmul_software_square_matches_opt() public {
        CLMULSoftware sw = new CLMULSoftware();
        uint256 expected = BinaryFieldLibOpt.squareGF2_128(a);
        uint256 result   = sw.squareGF2_128(a);
        assertEq(result, expected, "CLMULSoftware.squareGF2_128 must match BinaryFieldLibOpt");
    }

    // -----------------------------------------------------------------------
    // Precompile detection: extcodesize check
    // -----------------------------------------------------------------------

    function test_precompile_detection_returns_zero_when_nothing_deployed() public view {
        // Nothing deployed at 0xA0; precompileAddress() should return address(0)
        address detected = CLMULRouter.precompileAddress();
        assertEq(detected, address(0), "nothing at 0xA0");
    }

    function test_precompile_detection_returns_address_when_deployed() public {
        CLMULSoftware sw = new CLMULSoftware();
        vm.etch(CLMUL_PRECOMPILE_ADDRESS, address(sw).code);

        address detected = CLMULRouter.precompileAddress();
        assertEq(detected, CLMUL_PRECOMPILE_ADDRESS, "precompile detected at 0xA0");
    }

    // -----------------------------------------------------------------------
    // Gas benchmarks
    // -----------------------------------------------------------------------

    function test_gas_fallback_mul() public {
        uint256 g = gasleft();
        CLMULRouter.mulGF2_128(a, b);
        emit log_named_uint("CLMULRouter.mulGF2_128 (software fallback) gas", g - gasleft());
    }

    function test_gas_native_mul() public {
        CLMULSoftware sw = new CLMULSoftware();
        vm.etch(CLMUL_PRECOMPILE_ADDRESS, address(sw).code);

        uint256 g = gasleft();
        CLMULRouter.mulGF2_128(a, b);
        emit log_named_uint("CLMULRouter.mulGF2_128 (native path via etch) gas", g - gasleft());
    }
}
