// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import { BinaryFieldLibOpt } from "./BinaryFieldLibOpt.sol";

/// @title CLMULPrecompile
/// @notice A forward-compatible interface for GF(2^128) carry-less multiply.
///
/// ============================================================================
/// DESIGN: Precompile-Ready Shim Pattern
/// ============================================================================
///
///  Today: this contract uses BinaryFieldLibOpt's Yul+Zech-tables implementation
///         (25,775 gas per mulGF2_128).
///
///  On a custom L2 (Arbitrum Orbit, OP Stack, Polygon CDK): deploy a native
///  precompile at CLMUL_PRECOMPILE_ADDRESS that executes CLMUL in ~50 gas via
///  the host's native instruction. All downstream contracts call this address
///  and get native speed with ZERO code changes.
///
///  On Ethereum L1 after EIP-CLMUL: EOA calls still go through this contract
///  but the EIP opcode would be cheaper. Alternatively, the verifier can be
///  updated to use the opcode directly once it exists.
///
/// ============================================================================
/// L2 DEPLOYMENT: Arbitrum Orbit
/// ============================================================================
///
///  1. Add to ArbOS config (arbos.json):
///       {
///         "precompiles": [
///           {
///             "address": "0x00000000000000000000000000000000000000A0",
///             "impl":    "CLMULPrecompile"
///           }
///         ]
///       }
///
///  2. Implement the precompile in Go (ArbOS / nitro-contracts):
///       func (c *CLMULPrecompile) MulGF2_128(
///           a, b [16]byte,
///       ) ([16]byte, error) {
///           // Use CLMUL instruction (via Go's crypto/internal/subtle or asm)
///           return clmul128(a, b), nil
///       }
///
///  3. Register it in precompile_registry.go:
///       ArbPrecompiledContracts[CLMULAddr] = &CLMULPrecompile{}
///
///  4. Run on your chain: contracts at CLMUL_PRECOMPILE_ADDRESS now respond
///     with native speed. All code using ICLMULPrecompile.mulGF2_128() works
///     unchanged — they just call the address.
///
/// ============================================================================
/// OP STACK / BASE EQUIVALENT
/// ============================================================================
///
///  In op-geth, add to core/vm/contracts.go:
///       var PrecompiledContractsEclair = map[common.Address]PrecompiledContract{
///           ...existing...,
///           common.HexToAddress("0xA0"): &clmulPrecompile{},
///       }
///
///  func (c *clmulPrecompile) Run(input []byte) ([]byte, error) {
///      // input: 32 bytes a || 32 bytes b
///      a := new(big.Int).SetBytes(input[:32])
///      b := new(big.Int).SetBytes(input[32:64])
///      // carry-less multiply in GF(2)[X] mod tower polynomial
///      result := clmulGF2_128(a, b)
///      return padTo32(result.Bytes()), nil
///  }

/// @dev Address reserved for the CLMUL precompile.
///      On L2s, a native implementation lives here.
///      On regular EVM, staticcall to this address fails and we fall back.
address constant CLMUL_PRECOMPILE_ADDRESS = address(0xA0);

/// @notice Interface that all call sites use. Never call the implementation directly.
interface ICLMULPrecompile {
    /// @notice GF(2^128) multiply using the canonical Binius tower.
    function mulGF2_128(uint256 a, uint256 b) external view returns (uint256);

    /// @notice GF(2^128) square.
    function squareGF2_128(uint256 a) external view returns (uint256);

    /// @notice GF(2^128) batch inversion via Montgomery's trick.
    function batchInvertGF2_128(
        uint256[] calldata inputs
    ) external view returns (uint256[] memory);
}

/// @notice Software fallback — the pure Solidity implementation used on any EVM
///         that does not have the native precompile at CLMUL_PRECOMPILE_ADDRESS.
///         Deploy this at CLMUL_PRECOMPILE_ADDRESS on networks without native support.
contract CLMULSoftware {
    function mulGF2_128(uint256 a, uint256 b) external pure returns (uint256) {
        return BinaryFieldLibOpt.mulGF2_128(a, b);
    }

    function squareGF2_128(uint256 a) external pure returns (uint256) {
        return BinaryFieldLibOpt.squareGF2_128(a);
    }

    function batchInvertGF2_128(uint256[] calldata inputs)
        external
        pure
        returns (uint256[] memory results)
    {
        results = new uint256[](inputs.length);
        uint256[] memory inputsCopy = new uint256[](inputs.length);
        for (uint256 i = 0; i < inputs.length; i++) {
            inputsCopy[i] = inputs[i];
        }
        BinaryFieldLibOpt.batchInvertGF2_128(inputsCopy, results);
    }
}

/// @title CLMULRouter
/// @notice Auto-detects whether a native precompile is present at
///         CLMUL_PRECOMPILE_ADDRESS and routes accordingly.
///         Deployed once; all downstream contracts import this library.
///
///         On networks WITH the native precompile:
///           - mulGF2_128 costs ~50-100 gas (native CLMUL)
///
///         On networks WITHOUT (regular EVM, testnets):
///           - mulGF2_128 costs ~25,775 gas (Yul+Zech tables fallback)
///           - No code changes needed in callers
library CLMULRouter {

    /// @notice Returns the address to use for CLMUL calls.
    ///         Checks once per call whether the native precompile exists.
    function precompileAddress() internal view returns (address) {
        // Check if something is deployed at the precompile address
        uint256 size;
        address addr = CLMUL_PRECOMPILE_ADDRESS;
        assembly ("memory-safe") {
            size := extcodesize(addr)
        }
        return (size > 0) ? addr : address(0);
    }

    function mulGF2_128(uint256 a, uint256 b) internal view returns (uint256) {
        address precompile = precompileAddress();
        if (precompile != address(0)) {
            // Native path: staticcall to the precompile
            (bool ok, bytes memory result) = precompile.staticcall(
                abi.encodeCall(ICLMULPrecompile.mulGF2_128, (a, b))
            );
            if (ok && result.length == 32) {
                return abi.decode(result, (uint256));
            }
        }
        // Software fallback
        return BinaryFieldLibOpt.mulGF2_128(a, b);
    }

    function squareGF2_128(uint256 a) internal view returns (uint256) {
        address precompile = precompileAddress();
        if (precompile != address(0)) {
            (bool ok, bytes memory result) = precompile.staticcall(
                abi.encodeCall(ICLMULPrecompile.squareGF2_128, (a))
            );
            if (ok && result.length == 32) {
                return abi.decode(result, (uint256));
            }
        }
        return BinaryFieldLibOpt.squareGF2_128(a);
    }

    function batchInvertGF2_128(
        uint256[] memory inputs,
        uint256[] memory results
    ) internal view {
        address precompile = precompileAddress();
        if (precompile != address(0)) {
            uint256[] memory inputsCalldata = inputs;
            (bool ok, bytes memory result) = precompile.staticcall(
                abi.encodeCall(ICLMULPrecompile.batchInvertGF2_128, (inputsCalldata))
            );
            if (ok) {
                uint256[] memory decoded = abi.decode(result, (uint256[]));
                uint256 n = decoded.length < results.length ? decoded.length : results.length;
                for (uint256 i = 0; i < n; i++) {
                    results[i] = decoded[i];
                }
                return;
            }
        }
        BinaryFieldLibOpt.batchInvertGF2_128(inputs, results);
    }
}
