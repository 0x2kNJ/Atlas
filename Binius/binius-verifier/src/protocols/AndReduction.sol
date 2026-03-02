// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.28;

import "../GF128.sol";
import "../Transcript.sol";
import "./MleCheck.sol";

/// @title AndReduction — Rijndael zerocheck for AND constraints
/// @notice Verifies AND constraints via univariate zerocheck reduction.
///
///         Protocol:
///           1. Sample 15 big-field zerocheck challenges (Fiat-Shamir)
///              Combined with 3 fixed small-field constants → 18 total zerocheck challenges
///           2. Read 64 extension-domain evaluations from proof (1024 bytes)
///           3. Sample z_challenge from transcript
///           4. Compute sumcheck_claim = extrapolate_over_subspace(domain, evals, z)
///           5. Run MLE-check (18 rounds, degree=2) with all_zc as evaluation point
///           6. Read [a_eval, b_eval, c_eval] from proof (48 bytes)
///           7. Verify: a_eval * b_eval XOR c_eval == mlecheck_final_eval
///
///         Total proof bytes: 1024 + 576 + 48 = 1648 bytes
library AndReduction {
    using GF128 for uint256;
    using Transcript for Transcript.State;

    uint256 internal constant LOG_N_AND = 18;
    uint256 internal constant LOG_BATCH_SIZE = 3;
    uint256 internal constant N_BIG_FIELD = 15;
    uint256 internal constant N_ROWS_PER_VERTEX = 64;

    uint256 internal constant SMALL_FIELD_ZC_0 = 0x0dcb364640a222fe6b8330483c2e9849;
    uint256 internal constant SMALL_FIELD_ZC_1 = 0x3d5bd35c94646a247573da4a5f7710ed;
    uint256 internal constant SMALL_FIELD_ZC_2 = 0xa72ec17764d7ced55e2f716f4ede412f;

    uint256 internal constant EXT_DOMAIN_W = 0x0dcb364640a222fe6b8330483c2e9848;

    struct AndOutput {
        uint256 zChallenge;
        uint256[] evalPoint;
        uint256 aEval;
        uint256 bEval;
        uint256 cEval;
    }

    function verify(
        Transcript.State memory t
    ) internal view returns (AndOutput memory output) {
        // ── 1. Sample big-field zerocheck challenges ──────────────────────────
        uint256[] memory allZc = new uint256[](LOG_N_AND);
        allZc[0] = SMALL_FIELD_ZC_0;
        allZc[1] = SMALL_FIELD_ZC_1;
        allZc[2] = SMALL_FIELD_ZC_2;
        for (uint256 i = 0; i < N_BIG_FIELD; i++) {
            allZc[3 + i] = t.sampleGF128();
        }

        // ── 2. Read 64 extension-domain evaluations (1024 bytes) ─────────────
        uint256[] memory extEvals = new uint256[](N_ROWS_PER_VERTEX);
        for (uint256 i = 0; i < N_ROWS_PER_VERTEX; i++) {
            extEvals[i] = t.messageGF128();
        }

        // ── 3. Sample z_challenge ─────────────────────────────────────────────
        output.zChallenge = t.sampleGF128();

        // ── 4. Compute sumcheck_claim via extrapolate_over_subspace ────────────
        uint256 sumcheckClaim = _extrapolateOverSubspace(extEvals, output.zChallenge);

        // ── 5. Run MLE-check (18 rounds, degree=2) ────────────────────────────
        MleCheck.Result memory mlecResult = MleCheck.verify(t, allZc, 2, sumcheckClaim);

        // ── 6. Reverse eval_point ─────────────────────────────────────────────
        uint256[] memory challenges = mlecResult.challenges;
        uint256 n = challenges.length;
        uint256[] memory evalPoint = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            evalPoint[i] = challenges[n - 1 - i];
        }
        output.evalPoint = evalPoint;

        // ── 7. Read [a_eval, b_eval, c_eval] (48 bytes) ──────────────────────
        output.aEval = t.messageGF128();
        output.bEval = t.messageGF128();
        output.cEval = t.messageGF128();

        // ── 8. Verify AND constraint ──────────────────────────────────────────
        uint256 ab = GF128.mul(output.aEval, output.bEval);
        require(
            (ab ^ output.cEval) == mlecResult.finalEval,
            "AndReduction: a*b - c != mlecheck_eval"
        );
    }

    function _extrapolateOverSubspace(
        uint256[] memory extEvals,
        uint256 z
    ) internal pure returns (uint256) {
        uint256 prod = _computeBaseProd(z);

        uint256 acc = 0;
        uint256[64] memory extDomain = _getExtDomain();
        for (uint256 i = 0; i < 64; i++) {
            uint256 term = z ^ extDomain[i];
            acc = GF128.mul(acc, term) ^ GF128.mul(prod, extEvals[i]);
            prod = GF128.mul(prod, term);
        }

        return GF128.mul(acc, EXT_DOMAIN_W);
    }

    function _computeBaseProd(uint256 z) internal pure returns (uint256 prod) {
        prod = 1;
        uint256[64] memory baseDomain = _getBaseDomain();
        for (uint256 i = 0; i < 64; i++) {
            prod = GF128.mul(prod, z ^ baseDomain[i]);
        }
    }

    function _getBaseDomain() internal pure returns (uint256[64] memory d) {
        d[0] = 0x00000000000000000000000000000000;
        d[1] = 0x00000000000000000000000000000001;
        d[2] = 0x0dcb364640a222fe6b8330483c2e9849;
        d[3] = 0x0dcb364640a222fe6b8330483c2e9848;
        d[4] = 0x3d5bd35c94646a247573da4a5f7710ed;
        d[5] = 0x3d5bd35c94646a247573da4a5f7710ec;
        d[6] = 0x3090e51ad4c648da1ef0ea02635988a4;
        d[7] = 0x3090e51ad4c648da1ef0ea02635988a5;
        d[8] = 0x6d58c4e181f9199f41a12db1f974f3ac;
        d[9] = 0x6d58c4e181f9199f41a12db1f974f3ad;
        d[10] = 0x6093f2a7c15b3b612a221df9c55a6be5;
        d[11] = 0x6093f2a7c15b3b612a221df9c55a6be4;
        d[12] = 0x500317bd159d73bb34d2f7fba603e341;
        d[13] = 0x500317bd159d73bb34d2f7fba603e340;
        d[14] = 0x5dc821fb553f51455f51c7b39a2d7b08;
        d[15] = 0x5dc821fb553f51455f51c7b39a2d7b09;
        d[16] = 0xa72ec17764d7ced55e2f716f4ede412f;
        d[17] = 0xa72ec17764d7ced55e2f716f4ede412e;
        d[18] = 0xaae5f7312475ec2b35ac412772f0d966;
        d[19] = 0xaae5f7312475ec2b35ac412772f0d967;
        d[20] = 0x9a75122bf0b3a4f12b5cab2511a951c2;
        d[21] = 0x9a75122bf0b3a4f12b5cab2511a951c3;
        d[22] = 0x97be246db011860f40df9b6d2d87c98b;
        d[23] = 0x97be246db011860f40df9b6d2d87c98a;
        d[24] = 0xca760596e52ed74a1f8e5cdeb7aab283;
        d[25] = 0xca760596e52ed74a1f8e5cdeb7aab282;
        d[26] = 0xc7bd33d0a58cf5b4740d6c968b842aca;
        d[27] = 0xc7bd33d0a58cf5b4740d6c968b842acb;
        d[28] = 0xf72dd6ca714abd6e6afd8694e8dda26e;
        d[29] = 0xf72dd6ca714abd6e6afd8694e8dda26f;
        d[30] = 0xfae6e08c31e89f90017eb6dcd4f33a27;
        d[31] = 0xfae6e08c31e89f90017eb6dcd4f33a26;
        d[32] = 0x4d52354a3a3d8c865cb10fbabcf00118;
        d[33] = 0x4d52354a3a3d8c865cb10fbabcf00119;
        d[34] = 0x4099030c7a9fae7837323ff280de9951;
        d[35] = 0x4099030c7a9fae7837323ff280de9950;
        d[36] = 0x7009e616ae59e6a229c2d5f0e38711f5;
        d[37] = 0x7009e616ae59e6a229c2d5f0e38711f4;
        d[38] = 0x7dc2d050eefbc45c4241e5b8dfa989bc;
        d[39] = 0x7dc2d050eefbc45c4241e5b8dfa989bd;
        d[40] = 0x200af1abbbc495191d10220b4584f2b4;
        d[41] = 0x200af1abbbc495191d10220b4584f2b5;
        d[42] = 0x2dc1c7edfb66b7e77693124379aa6afd;
        d[43] = 0x2dc1c7edfb66b7e77693124379aa6afc;
        d[44] = 0x1d5122f72fa0ff3d6863f8411af3e259;
        d[45] = 0x1d5122f72fa0ff3d6863f8411af3e258;
        d[46] = 0x109a14b16f02ddc303e0c80926dd7a10;
        d[47] = 0x109a14b16f02ddc303e0c80926dd7a11;
        d[48] = 0xea7cf43d5eea4253029e7ed5f22e4037;
        d[49] = 0xea7cf43d5eea4253029e7ed5f22e4036;
        d[50] = 0xe7b7c27b1e4860ad691d4e9dce00d87e;
        d[51] = 0xe7b7c27b1e4860ad691d4e9dce00d87f;
        d[52] = 0xd7272761ca8e287777eda49fad5950da;
        d[53] = 0xd7272761ca8e287777eda49fad5950db;
        d[54] = 0xdaec11278a2c0a891c6e94d79177c893;
        d[55] = 0xdaec11278a2c0a891c6e94d79177c892;
        d[56] = 0x872430dcdf135bcc433f53640b5ab39b;
        d[57] = 0x872430dcdf135bcc433f53640b5ab39a;
        d[58] = 0x8aef069a9fb1793228bc632c37742bd2;
        d[59] = 0x8aef069a9fb1793228bc632c37742bd3;
        d[60] = 0xba7fe3804b7731e8364c892e542da376;
        d[61] = 0xba7fe3804b7731e8364c892e542da377;
        d[62] = 0xb7b4d5c60bd513165dcfb96668033b3f;
        d[63] = 0xb7b4d5c60bd513165dcfb96668033b3e;
    }

    function _getExtDomain() internal pure returns (uint256[64] memory d) {
        d[0] = 0x553e92e8bc0ae9a795ed1f57f3632d4d;
        d[1] = 0x553e92e8bc0ae9a795ed1f57f3632d4c;
        d[2] = 0x58f5a4aefca8cb59fe6e2f1fcf4db504;
        d[3] = 0x58f5a4aefca8cb59fe6e2f1fcf4db505;
        d[4] = 0x686541b4286e8383e09ec51dac143da0;
        d[5] = 0x686541b4286e8383e09ec51dac143da1;
        d[6] = 0x65ae77f268cca17d8b1df555903aa5e9;
        d[7] = 0x65ae77f268cca17d8b1df555903aa5e8;
        d[8] = 0x386656093df3f038d44c32e60a17dee1;
        d[9] = 0x386656093df3f038d44c32e60a17dee0;
        d[10] = 0x35ad604f7d51d2c6bfcf02ae363946a8;
        d[11] = 0x35ad604f7d51d2c6bfcf02ae363946a9;
        d[12] = 0x053d8555a9979a1ca13fe8ac5560ce0c;
        d[13] = 0x053d8555a9979a1ca13fe8ac5560ce0d;
        d[14] = 0x08f6b313e935b8e2cabcd8e4694e5645;
        d[15] = 0x08f6b313e935b8e2cabcd8e4694e5644;
        d[16] = 0xf210539fd8dd2772cbc26e38bdbd6c62;
        d[17] = 0xf210539fd8dd2772cbc26e38bdbd6c63;
        d[18] = 0xffdb65d9987f058ca0415e708193f42b;
        d[19] = 0xffdb65d9987f058ca0415e708193f42a;
        d[20] = 0xcf4b80c34cb94d56beb1b472e2ca7c8f;
        d[21] = 0xcf4b80c34cb94d56beb1b472e2ca7c8e;
        d[22] = 0xc280b6850c1b6fa8d532843adee4e4c6;
        d[23] = 0xc280b6850c1b6fa8d532843adee4e4c7;
        d[24] = 0x9f48977e59243eed8a63438944c99fce;
        d[25] = 0x9f48977e59243eed8a63438944c99fcf;
        d[26] = 0x9283a13819861c13e1e073c178e70787;
        d[27] = 0x9283a13819861c13e1e073c178e70786;
        d[28] = 0xa2134422cd4054c9ff1099c31bbe8f23;
        d[29] = 0xa2134422cd4054c9ff1099c31bbe8f22;
        d[30] = 0xafd872648de276379493a98b2790176a;
        d[31] = 0xafd872648de276379493a98b2790176b;
        d[32] = 0x186ca7a286376521c95c10ed4f932c55;
        d[33] = 0x186ca7a286376521c95c10ed4f932c54;
        d[34] = 0x15a791e4c69547dfa2df20a573bdb41c;
        d[35] = 0x15a791e4c69547dfa2df20a573bdb41d;
        d[36] = 0x253774fe12530f05bc2fcaa710e43cb8;
        d[37] = 0x253774fe12530f05bc2fcaa710e43cb9;
        d[38] = 0x28fc42b852f12dfbd7acfaef2ccaa4f1;
        d[39] = 0x28fc42b852f12dfbd7acfaef2ccaa4f0;
        d[40] = 0x7534634307ce7cbe88fd3d5cb6e7dff9;
        d[41] = 0x7534634307ce7cbe88fd3d5cb6e7dff8;
        d[42] = 0x78ff5505476c5e40e37e0d148ac947b0;
        d[43] = 0x78ff5505476c5e40e37e0d148ac947b1;
        d[44] = 0x486fb01f93aa169afd8ee716e990cf14;
        d[45] = 0x486fb01f93aa169afd8ee716e990cf15;
        d[46] = 0x45a48659d3083464960dd75ed5be575d;
        d[47] = 0x45a48659d3083464960dd75ed5be575c;
        d[48] = 0xbf4266d5e2e0abf497736182014d6d7a;
        d[49] = 0xbf4266d5e2e0abf497736182014d6d7b;
        d[50] = 0xb2895093a242890afcf051ca3d63f533;
        d[51] = 0xb2895093a242890afcf051ca3d63f532;
        d[52] = 0x8219b5897684c1d0e200bbc85e3a7d97;
        d[53] = 0x8219b5897684c1d0e200bbc85e3a7d96;
        d[54] = 0x8fd283cf3626e32e89838b806214e5de;
        d[55] = 0x8fd283cf3626e32e89838b806214e5df;
        d[56] = 0xd21aa2346319b26bd6d24c33f8399ed6;
        d[57] = 0xd21aa2346319b26bd6d24c33f8399ed7;
        d[58] = 0xdfd1947223bb9095bd517c7bc417069f;
        d[59] = 0xdfd1947223bb9095bd517c7bc417069e;
        d[60] = 0xef417168f77dd84fa3a19679a74e8e3b;
        d[61] = 0xef417168f77dd84fa3a19679a74e8e3a;
        d[62] = 0xe28a472eb7dffab1c822a6319b601672;
        d[63] = 0xe28a472eb7dffab1c822a6319b601673;
    }
}
