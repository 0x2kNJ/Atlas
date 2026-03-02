// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICircuit1Verifier} from "../interfaces/ICircuit1Verifier.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title BiniusCircuit1Verifier
/// @notice ICircuit1Verifier adapter for Binius64 proofs.
///
/// ─── Architecture ────────────────────────────────────────────────────────────
///
/// Binius64 proofs are generated off-chain in ~170ms (Rust prover on commodity
/// hardware) and verified off-chain in ~50ms (Rust verifier). The proof is
/// 284 KiB — too large for cost-effective direct EVM verification today.
///
/// This contract uses a **trusted attester** model as a stepping stone:
///
///   1. Agent generates a Binius64 compliance proof (173ms).
///   2. A registered attester runs the Rust verifier (47ms) and signs an
///      attestation binding the proof digest to the public inputs.
///   3. The attestation + proof digest are submitted on-chain.
///   4. This contract recovers the attester's signature and checks it is
///      authorized, completing the verification.
///
/// ─── Upgrade Path ────────────────────────────────────────────────────────────
///
/// When EVM gas economics improve or a recursive SNARK wrapper becomes
/// available, this contract can be replaced (via CreditVerifier.proposeVerifier)
/// with one that calls Binius64Verifier.verify() directly on-chain.
///
/// The full on-chain verification pipeline already exists in:
///   Binius/binius-verifier/src/Binius64Verifier.sol
///
/// ─── Attestation Format ──────────────────────────────────────────────────────
///
/// The `proof` bytes passed to verify() must be:
///   abi.encode(bytes32 proofDigest, bytes signature)
///
/// The attester signs (EIP-191 personal_sign):
///   keccak256(abi.encodePacked(
///     proofDigest,
///     capabilityHash,
///     n,
///     accumulatorRoot,
///     adapterFilter,
///     minReturnBps
///   ))
///
/// proofDigest is keccak256(rawBinius64ProofBytes) — this binds the attestation
/// to a specific proof so attesters cannot be tricked into signing arbitrary data.

contract BiniusCircuit1Verifier is Ownable2Step, ICircuit1Verifier {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Authorized attesters. An attester is any off-chain service that
    ///         runs the Binius64 Rust verifier and signs valid results.
    mapping(address attester => bool authorized) public attesters;

    /// @notice Tracks used proof digests to prevent replay.
    mapping(bytes32 proofDigest => bool used) public usedProofs;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event AttesterSet(address indexed attester, bool authorized);
    event ProofAttested(
        bytes32 indexed proofDigest,
        bytes32 indexed capabilityHash,
        address indexed attester
    );

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error UnauthorizedAttester(address recovered);
    error ProofAlreadyUsed(bytes32 proofDigest);
    error ZeroAddress();

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _owner, address _initialAttester) Ownable(_owner) {
        if (_initialAttester == address(0)) revert ZeroAddress();
        attesters[_initialAttester] = true;
        emit AttesterSet(_initialAttester, true);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────

    function setAttester(address _attester, bool _authorized) external onlyOwner {
        if (_attester == address(0)) revert ZeroAddress();
        attesters[_attester] = _authorized;
        emit AttesterSet(_attester, _authorized);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ICircuit1Verifier
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc ICircuit1Verifier
    function verify(
        bytes calldata proof,
        PublicInputs calldata inputs
    ) external override returns (bool) {
        (bytes32 proofDigest, bytes memory signature) = abi.decode(proof, (bytes32, bytes));

        if (usedProofs[proofDigest]) revert ProofAlreadyUsed(proofDigest);

        bytes32 message = _attestationHash(proofDigest, inputs);
        bytes32 ethSignedHash = message.toEthSignedMessageHash();
        address signer = ethSignedHash.recover(signature);

        if (!attesters[signer]) revert UnauthorizedAttester(signer);

        usedProofs[proofDigest] = true;
        emit ProofAttested(proofDigest, inputs.capabilityHash, signer);

        return true;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View — useful for off-chain attester to reconstruct the signing payload
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns the message hash that the attester must sign.
    function attestationHash(
        bytes32 proofDigest,
        PublicInputs calldata inputs
    ) external pure returns (bytes32) {
        return _attestationHash(proofDigest, inputs);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────────────────

    function _attestationHash(
        bytes32 proofDigest,
        PublicInputs calldata inputs
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                proofDigest,
                inputs.capabilityHash,
                inputs.n,
                inputs.accumulatorRoot,
                inputs.adapterFilter,
                inputs.minReturnBps
            )
        );
    }
}
