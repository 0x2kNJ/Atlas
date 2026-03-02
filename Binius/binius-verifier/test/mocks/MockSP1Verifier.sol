// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

/// @title MockSP1Verifier
/// @notice Test double for the SP1VerifierGateway.
///         Three configurable modes:
///           PASS (default): verifyProof() always succeeds
///           FAIL:           verifyProof() always reverts
///           VKEY_STRICT:    reverts unless the exact expected vkey is supplied

contract MockSP1Verifier {
    enum Mode { PASS, FAIL, VKEY_STRICT }

    Mode public mode;
    bytes32 public expectedVkey;
    uint256 public callCount;

    event ProofVerified(bytes32 indexed programVKey, uint256 publicValuesLen);

    constructor() {
        mode = Mode.PASS;
    }

    function setMode(Mode m) external { mode = m; }
    function setExpectedVkey(bytes32 vkey) external { expectedVkey = vkey; }

    /// @notice Matches ISP1Verifier interface used by Binius64SP1Verifier.
    function verifyProof(
        bytes32 programVKey,
        bytes calldata publicValues,
        bytes calldata /* proofBytes */
    ) external {
        callCount++;
        if (mode == Mode.FAIL) {
            revert("MockSP1Verifier: proof rejected");
        }
        if (mode == Mode.VKEY_STRICT) {
            require(programVKey == expectedVkey, "MockSP1Verifier: wrong vkey");
        }
        emit ProofVerified(programVKey, publicValues.length);
    }
}
