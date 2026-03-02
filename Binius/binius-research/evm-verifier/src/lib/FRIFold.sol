// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "./GF128.sol";

/// @title FRIFold — FRI fold operations for binius64 BaseFold verification
/// @notice Implements fold_interleaved_chunk (trace fold) and fold_chunk (NTT fold)
///         for the binius64 FRI polynomial commitment verification.
///
///         The NTT fold uses precomputed twiddle basis elements derived from a
///         two-level NTT construction:
///           1. Initial NTT from canonical BinarySubspace::with_dim(18)
///           2. RS code subspace = ntt.subspace(14) (non-canonical basis)
///           3. Verifier NTT = GenericOnTheFly::generate_from_subspace(rs_code_subspace)
///
///         log_domain_size = 14, log_batch_size = 4, fold_arities = [4, 4]
library FRIFold {
    using GF128 for uint256;

    uint256 constant COSET_SIZE = 16; // 2^log_batch_size

    // ─────────────────────────────────────────────────────
    // Interleaved fold (trace oracle → single value)
    // ─────────────────────────────────────────────────────

    /// @notice Fold an interleaved coset using eq_ind tensor product.
    ///         result = Σ values[i] * eq_tensor[i], where eq_tensor comes from
    ///         the first 4 sumcheck challenges (the "interleave challenges").
    /// @param values   16 GF128 coset values from the trace oracle
    /// @param challenges First 4 challenges (challenges[0..4])
    function foldInterleaved(
        uint256[] memory values,
        uint256[] memory challenges
    ) internal pure returns (uint256 result) {
        // Compute eq_ind tensor matching binius tensor_prod_eq_ind.
        // For each challenge r_k, the existing buffer [0..size) is split:
        //   lo[i] = tensor[i] * (1-r_k)       (indices 0..size stay in-place)
        //   hi[i] = tensor[i] * r_k            (indices size..2*size appended)
        // Bit j of index i corresponds to challenge r_j.
        uint256[16] memory tensor;
        tensor[0] = 1;

        uint256 size = 1;
        for (uint256 k = 0; k < 4; k++) {
            uint256 r = challenges[k];
            uint256 oneMinusR = r ^ 1;
            for (uint256 i = 0; i < size; i++) {
                uint256 base = tensor[i];
                tensor[i] = GF128.mul(base, oneMinusR);
                tensor[size + i] = GF128.mul(base, r);
            }
            size <<= 1;
        }

        // Inner product: result = Σ values[i] * tensor[i]
        result = 0;
        for (uint256 i = 0; i < 16; i++) {
            result ^= GF128.mul(values[i], tensor[i]);
        }
    }

    // ─────────────────────────────────────────────────────
    // NTT fold (oracle coset → single value using twiddle factors)
    // ─────────────────────────────────────────────────────

    /// @notice Fold a coset of 16 elements using 4 challenges with NTT twiddle factors.
    ///         This implements fold_chunk from the binius FRI verifier.
    /// @param values     16 GF128 coset values
    /// @param challenges 4 fold challenges
    /// @param logLen     log2 of the current codeword length (14 for oracle1, 10 for oracle2)
    /// @param chunkIndex Index of the coset in the current oracle
    function foldChunk(
        uint256[] memory values,
        uint256[] memory challenges,
        uint256 logLen,
        uint256 chunkIndex
    ) internal pure returns (uint256) {
        // Copy values to mutable buffer
        uint256[16] memory buf;
        for (uint256 i = 0; i < 16; i++) {
            buf[i] = values[i];
        }

        uint256 logSize = 4; // log2(16) = 4

        for (uint256 k = 0; k < 4; k++) {
            uint256 challenge = challenges[k];
            uint256 halfSize = 1 << (logSize - 1);

            for (uint256 indexOffset = 0; indexOffset < halfSize; indexOffset++) {
                uint256 u = buf[indexOffset << 1];
                uint256 v = buf[(indexOffset << 1) | 1];
                uint256 pairIndex = (chunkIndex << (logSize - 1)) | indexOffset;

                buf[indexOffset] = _foldPair(logLen, pairIndex, u, v, challenge);
            }

            logLen -= 1;
            logSize -= 1;
        }

        return buf[0];
    }

    /// @notice Single fold_pair: inverse NTT butterfly + line extrapolation.
    ///         t = twiddle(logLen - 1, index)
    ///         v' = u + v
    ///         u' = u + v' * t
    ///         result = u' + r * (v' + u')
    function _foldPair(
        uint256 logLen,
        uint256 index,
        uint256 u,
        uint256 v,
        uint256 r
    ) private pure returns (uint256) {
        uint256 t = _twiddle(logLen - 1, index);
        // Inverse NTT butterfly
        v = u ^ v;              // v' = u + v
        u = u ^ GF128.mul(v, t); // u' = u + v' * t
        // Line extrapolation: u' + r * (v' + u') = u' + r * (v' XOR u')
        return u ^ GF128.mul(r, v ^ u);
    }

    // ─────────────────────────────────────────────────────
    // Twiddle factor computation from precomputed basis
    // ─────────────────────────────────────────────────────

    /// @notice Compute twiddle(layer, block) by XOR-ing basis elements for set bits.
    /// @dev For the verifier's derived NTT (log_domain_size=14, non-canonical subspace).
    ///      Layer N has N basis elements; twiddle(layer, block) = XOR of basis[i] for set bits in block.
    function _twiddle(uint256 layer, uint256 block) private pure returns (uint256 result) {
        result = 0;
        if (block == 0) return 0;

        uint256 nBasis = layer;
        require(layer >= 6 && layer <= 13, "FRIFold: unsupported layer");

        for (uint256 i = 0; i < nBasis; i++) {
            if ((block >> i) & 1 == 1) {
                result ^= _twiddleBasis(layer, i);
            }
        }
    }

    /// @notice Lookup precomputed twiddle basis element for (layer, basisIndex).
    /// @dev Generated by export_twiddle_basis.rs using the two-level NTT construction:
    ///      initial_ntt = GenericOnTheFly(BinarySubspace::with_dim(18))
    ///      rs_subspace = initial_ntt.subspace(14)
    ///      verifier_ntt = GenericOnTheFly(rs_subspace)
    function _twiddleBasis(uint256 layer, uint256 idx) private pure returns (uint256) {
        // Layer 13 (13 basis elements)
        if (layer == 13) {
            if (idx == 0) return 0x00000000000000000000000000010116;
            if (idx == 1) return 0x0000000000000000000000010117177c;
            if (idx == 2) return 0x000000000000000000010117166b6bb8;
            if (idx == 3) return 0x00000000000000010117166a7cd2c270;
            if (idx == 4) return 0x0000000000010117166a7dc5a8a5d0e0;
            if (idx == 5) return 0x000000010117166a7dc4bfcf044af1c0;
            if (idx == 6) return 0x00010117166a7dc4bed86e9e4c90a380;
            if (idx == 7) return 0x0117166a7dc4bed979f4982c89344787;
            if (idx == 8) return 0x166a7dc4bed978e3f2f8350952bb02e5;
            if (idx == 9) return 0x7dc4bed978e2e592e1b56ed429c74a16;
            if (idx == 10) return 0xbed978e2e4858b61d2e8514d193bab5c;
            if (idx == 11) return 0x78e2e4849c0b06546d34e97f1824248f;
            if (idx == 12) return 0xe4849d1c6c80d1089098fded16fafbae;
        }
        // Layer 12 (12 basis elements)
        if (layer == 12) {
            if (idx == 0) return 0x00000000000000000000000100010116;
            if (idx == 1) return 0x0000000000000001000101170117177c;
            if (idx == 2) return 0x00000001000101170116166b166b6bb8;
            if (idx == 3) return 0x000101170116166a177c7dd27cd2c2f7;
            if (idx == 4) return 0x0116166a177d7cc56ab8bf32a8225c05;
            if (idx == 5) return 0x177d7cc46bafa958d5e6e3ca8823a7d6;
            if (idx == 6) return 0x6baea84fc38c9e0e36fbc943965cb7dc;
            if (idx == 7) return 0xc29b88644b3f779aefa82fc44c2939ea;
            if (idx == 8) return 0x5d550a5e51715727bed10c8052bd89d9;
            if (idx == 9) return 0x2cb5e9fec633e912b308e72211e9528c;
            if (idx == 10) return 0x78ea91f0578d6c43c30103d784c6c9a6;
            if (idx == 11) return 0x2f6f88c75f0a0583e9f220e407f9295f;
        }
        // Layer 11 (11 basis elements)
        if (layer == 11) {
            if (idx == 0) return 0x00000000000000010000000100010116;
            if (idx == 1) return 0x000000010001011700010117011717fb;
            if (idx == 2) return 0x00010116011616ec011616ec16ece75d;
            if (idx == 3) return 0x011717fb17faf13717fbf1b0f0bbd473;
            if (idx == 4) return 0x16ede7dae7c6a8b6e656255832be1000;
            if (idx == 5) return 0xf12b599c5911b953c394b9bddc26a7d4;
            if (idx == 6) return 0xa83a11f21faa39a074878bba91f430e5;
            if (idx == 7) return 0xb61c03dedacb4728aa06a315c763458a;
            if (idx == 8) return 0xf753a94b961212f5b284e8f5336ec801;
            if (idx == 9) return 0x9e31010bf55d216ade661c1bfa9e54c7;
            if (idx == 10) return 0xa68c8debad1338c80116811ee0c59ab0;
        }
        // Layer 10 (10 basis elements)
        if (layer == 10) {
            if (idx == 0) return 0x00000000000000010000000100010191;
            if (idx == 1) return 0x0000000100010190000101900190db8c;
            if (idx == 2) return 0x000101910191da1c0191da1cda7323f9;
            if (idx == 3) return 0x0190db8cdbe2f963dbe3f98bce73c31c;
            if (idx == 4) return 0xda7223111516f77014010c0c6004d754;
            if (idx == 5) return 0xcf643861b90ac509af159ba8fe531ff5;
            if (idx == 6) return 0x761a880ab5fce64bb3229d9f43c2a615;
            if (idx == 7) return 0xf91dbeb12d4ed10322a5bc68ed7d20c7;
            if (idx == 8) return 0x96dcc8caf392a46d0d22e9990f8d77ae;
            if (idx == 9) return 0x10431e06e6f26aef6cfe4c531287e075;
        }
        // Layer 9 (9 basis elements)
        if (layer == 9) {
            if (idx == 0) return 0x00000000000000010000000100014184;
            if (idx == 1) return 0x00000001000141850001418551e18458;
            if (idx == 2) return 0x0001418451e0c5dd51e0d1a1b31af341;
            if (idx == 3) return 0x51e19024e2fa2266e7e518713c7d8949;
            if (idx == 4) return 0xb605c956db3fc31a543dbdb5080ffcdd;
            if (idx == 5) return 0xb37ff7ce4df0aed08768499aa9bd9934;
            if (idx == 6) return 0xc2964f653b703f0b4d09c1aab10b6593;
            if (idx == 7) return 0x8b6f74cf433f31d3fb7dcd8151918c7e;
            if (idx == 8) return 0x5bcaf30343d6b111df149e6c624c097f;
        }
        // Layer 8 (8 basis elements)
        if (layer == 8) {
            if (idx == 0) return 0x00000000000000010000000110014095;
            if (idx == 1) return 0x00000001100140941101548c10b4589d;
            if (idx == 2) return 0x1101548d01a50d5190ab0475ccb3bf0c;
            if (idx == 3) return 0x81bb51ad45081bf98a311564c7300c0d;
            if (idx == 4) return 0x430aaed55e0e8fa7007b9a9e69abfc79;
            if (idx == 5) return 0x9f9189ea8d9ec5ae1daa5b4e6593db8b;
            if (idx == 6) return 0x9d4f5ef0101dabedc6045ddb6f1dc190;
            if (idx == 7) return 0x8c8aef9093338cf9ef904a9e05c5b30f;
        }
        // Layer 7 (7 basis elements)
        if (layer == 7) {
            if (idx == 0) return 0x00000000000000010100000110004194;
            if (idx == 1) return 0x01010001111040d58400459d41618d09;
            if (idx == 2) return 0xc48544c8dd617d8d58f41ac8eea9edc5;
            if (idx == 3) return 0x09eaf4c34c771a35990a11517973c17c;
            if (idx == 4) return 0x614edf3c2e2f4ac0faf94d6a4cbf456a;
            if (idx == 5) return 0xafc6bd9aac770a2808f5b75470ef2d5a;
            if (idx == 6) return 0x61a6200695386e1582bec1ed4eaf8e63;
        }
        // Layer 6 (6 basis elements)
        if (layer == 6) {
            if (idx == 0) return 0x00010000000000010100000010014195;
            if (idx == 1) return 0x40950087101141d495869309107abc9c;
            if (idx == 2) return 0x283b9ce1593f420061640edeb6b2d441;
            if (idx == 3) return 0x305ab671902627928e33e95399ba2e25;
            if (idx == 4) return 0x597e62272c34e9d33b99a0d17090fd38;
            if (idx == 5) return 0x45be2b106f6aa6499789f41cc6aec79d;
        }
        revert("FRIFold: invalid twiddle basis lookup");
    }
}
