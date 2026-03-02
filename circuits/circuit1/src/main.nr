/// Circuit 1 -- Selective Disclosure Proof for Atlas x Clawloan credit attestation.
///
/// What This Circuit Proves
/// ------------------------
///
/// "I know N execution receipts committed under capability `capability_hash` that:
///  1. Sequentially reproduce the on-chain `accumulator_root` from ReceiptAccumulator.sol.
///     Any omitted receipt causes the root to diverge -- cherry-picking is impossible.
///  2. Were all executed through the `adapter_filter` address (e.g. ClawloanRepayAdapter).
///     Adapter is part of the rolling root commitment, so this is fully binding.
///  3. All satisfy amountOut >= amountIn * min_return_bps / 10_000.
///     Proves minimum profitability per repayment."
///
/// Circuit Parameters
/// ------------------
///
/// MAX_N = 64 receipts (covers all credit tiers including PLATINUM at 50 repayments).
///
/// Tier coverage:
///   NEW      (0  repayments) -> MAX_N >= 1
///   BRONZE   (1-5           ) -> MAX_N >= 5
///   SILVER   (6-20          ) -> MAX_N >= 20
///   GOLD     (21-49         ) -> MAX_N >= 49
///   PLATINUM (50+           ) -> MAX_N >= 50  (covered by MAX_N = 64)
///
/// Inactive slots (i >= n) are always zero-padded and skipped by the circuit,
/// so a proof for n=1 still produces a valid UltraHonk proof; the extra 63 zero
/// slots add a fixed gate overhead (~43k gates / active receipt) that scales
/// linearly with MAX_N but is paid regardless of n.
///
/// Rolling Root Formula (must match ReceiptAccumulator.sol exactly)
/// ----------------------------------------------------------------
///
///   root_0 = [0u8; 32]
///   root_i = keccak256(abi.encode(root_{i-1}, i-1, receiptHash_i, nullifier_i, adapter_i))
///          = keccak256( root_{i-1}    [32 bytes]
///                     | (i-1 as u256) [32 bytes, big-endian zero-padded]
///                     | receiptHash_i [32 bytes]
///                     | nullifier_i   [32 bytes]
///                     | adapter_i     [32 bytes, address zero-padded to 32 bytes]
///                     )               [total: 160 bytes]
///
/// Public Inputs
/// -------------
///
///   n                  Number of receipts being proven (1 <= n <= MAX_N).
///   accumulator_root   bytes32 from ReceiptAccumulator.rollingRoot(capabilityHash).
///   capability_hash    bytes32 -- the capability whose receipts are being proven.
///   adapter_filter     bytes32 (zero-padded address). [0;32] = no filter.
///   min_return_bps     u64. 0 = no minimum. Otherwise amountOut >= amountIn*bps/10_000.
///
/// Private Inputs
/// --------------
///
///   receipt_hashes   [[u8; 32]; MAX_N]  -- padded to 64 slots; unused slots = [0u8; 32]
///   nullifiers       [[u8; 32]; MAX_N]  -- padded to 64 slots; unused slots = [0u8; 32]
///   adapters         [[u8; 32]; MAX_N]  -- zero-padded adapter addresses; 64 slots
///   amounts_in       [u128; MAX_N]      -- u128 to handle 18-decimal assets without overflow
///   amounts_out      [u128; MAX_N]      -- u128 to handle 18-decimal assets without overflow
///
/// For indices i >= n (inactive slots): provide zero bytes -- circuit ignores them.

use dep::keccak256::keccak256;

global MAX_N: u32 = 64;

/// Encode one rolling root update in the 160-byte abi.encode format:
///   [32] prev_root | [32] index (uint256 big-endian) | [32] receipt_hash | [32] nullifier | [32] adapter
fn encode_root_update(
    prev_root:    [u8; 32],
    index:        u32,
    receipt_hash: [u8; 32],
    nullifier:    [u8; 32],
    adapter:      [u8; 32],
) -> [u8; 160] {
    let mut input = [0u8; 160];

    // [0..32] prev_root
    for j in 0..32 {
        input[j] = prev_root[j];
    }

    // [32..64] index as uint256 big-endian (Field fits u32, to_be_bytes gives 32 bytes)
    let index_bytes = (index as Field).to_be_bytes::<32>();
    for j in 0..32 {
        input[32 + j] = index_bytes[j];
    }

    // [64..96] receipt_hash
    for j in 0..32 {
        input[64 + j] = receipt_hash[j];
    }

    // [96..128] nullifier
    for j in 0..32 {
        input[96 + j] = nullifier[j];
    }

    // [128..160] adapter (zero-padded address -- abi.encode(address) = 12 zero bytes + 20 addr bytes)
    for j in 0..32 {
        input[128 + j] = adapter[j];
    }

    input
}

/// Core verification logic. Uses MAX as a generic so the caller can choose circuit size.
///
/// amounts_in / amounts_out use u128 to safely handle 18-decimal assets (e.g. ETH).
/// With u64 the maximum representable amount is ~18.4e18, which overflows for any ETH
/// position > 18 ETH when expressed in wei. u128 raises that ceiling to ~3.4e38.
///
fn verify_receipts<let MAX: u32>(
    // Public inputs
    n:                u32,
    accumulator_root: [u8; 32],
    capability_hash:  [u8; 32],
    adapter_filter:   [u8; 32],
    min_return_bps:   u64,
    // Private inputs
    receipt_hashes:   [[u8; 32]; MAX],
    nullifiers:       [[u8; 32]; MAX],
    adapters:         [[u8; 32]; MAX],
    amounts_in:       [u128; MAX],
    amounts_out:      [u128; MAX],
) {
    // n must be in range [1, MAX].
    assert(n >= 1);
    assert(n <= MAX as u32);

    // capability_hash is a public binding commitment.
    // Ensure it is non-zero across ALL 32 bytes so the compiler cannot trivially satisfy
    // the constraint with a partially-zero hash (previously only bytes [0..7] were checked —
    // C-1 fix: fold all 32 bytes to prevent a prover from supplying a hash whose first 8
    // bytes are zero while the remaining 24 bytes are non-zero, or any other partial-zero input).
    let mut cap_non_zero: u8 = 0;
    for k in 0..32 {
        cap_non_zero = cap_non_zero | capability_hash[k];
    }
    assert(cap_non_zero != 0, "capability_hash must be non-zero");

    let zero_filter = [0u8; 32];
    let mut rolling_root = [0u8; 32];

    for i in 0..MAX {
        let is_active: bool = (i as u32) < n;

        if is_active {
            // Constraint 1: Adapter filter
            // If adapter_filter != [0;32], this receipt's adapter must match exactly.
            if adapter_filter != zero_filter {
                assert(
                    adapters[i] == adapter_filter,
                    "receipt adapter does not match adapter_filter"
                );
            }

            // Constraint 2: Minimum return (amountOut >= amountIn * min_return_bps / 10_000)
            //
            // H-1 overflow guard: amounts_in[i] * (min_return_bps as u128) can overflow u128
            // when amounts_in > u128::MAX / min_return_bps (e.g. amounts_in > 2^114 at bps=10_000).
            // In Noir, u128 arithmetic uses two u64 limbs; overflow wraps and produces an
            // arbitrarily small floor, allowing a prover to pass a receipt that fails the
            // real return floor.  We guard by asserting the multiplication is safe before
            // performing it.  u128 max = 340282366920938463463374607431768211455.
            //
            // Safe iff: amounts_in[i] <= u128::MAX / min_return_bps
            // Equivalently: amounts_in[i] * min_return_bps <= u128::MAX  (no overflow)
            if min_return_bps > 0 {
                let bps128 = min_return_bps as u128;
                // 340282366920938463463374607431768211455 / bps128 gives the max safe amounts_in.
                // We check amounts_in <= floor(MAX_U128 / bps128) to ensure no overflow.
                let max_safe_amount: u128 = 340282366920938463463374607431768211455 / bps128;
                assert(
                    amounts_in[i] <= max_safe_amount,
                    "amounts_in overflow: too large for min_return_bps multiplication"
                );
                let floor: u128 = amounts_in[i] * bps128 / 10_000;
                assert(
                    amounts_out[i] >= floor,
                    "receipt does not meet minimum return floor"
                );
            }

            // Constraint 3: Rolling root update
            // Replicate: keccak256(abi.encode(prev_root, i, receipt_hash, nullifier, adapter))
            let encoded = encode_root_update(
                rolling_root,
                i as u32,
                receipt_hashes[i],
                nullifiers[i],
                adapters[i],
            );
            rolling_root = keccak256(encoded, 160);
        }
        // L-1: Inactive slots (i >= n) must be fully zeroed.
        //
        // Without this constraint a prover can embed arbitrary data (including real
        // on-chain receipts from other capabilities) in inactive padding slots.
        // Although inactive slots do not affect the rolling root or any other soundness
        // constraint today, they represent a privacy leak: an observer who knows real
        // receipt values could correlate a proof to specific on-chain activity via the
        // private inputs.  Future circuit extensions that inspect inactive slots would
        // also be unsound without this invariant.
        //
        // We enforce that all witness values for inactive slots equal their zero defaults.
        if !is_active {
            assert(receipt_hashes[i] == [0u8; 32], "inactive receipt_hash must be zero");
            assert(nullifiers[i]     == [0u8; 32], "inactive nullifier must be zero");
            assert(adapters[i]       == [0u8; 32], "inactive adapter must be zero");
            assert(amounts_in[i]     == 0,         "inactive amounts_in must be zero");
            assert(amounts_out[i]    == 0,         "inactive amounts_out must be zero");
        }
    }

    // The rolling root after exactly n active receipts must equal the on-chain root.
    // This is the core anti-fabrication guarantee: any omission causes a mismatch here.
    assert(rolling_root == accumulator_root, "rolling root does not match accumulator_root");
}

fn main(
    // Public inputs
    n:                pub u32,
    accumulator_root: pub [u8; 32],
    capability_hash:  pub [u8; 32],
    adapter_filter:   pub [u8; 32],
    min_return_bps:   pub u64,

    // Private inputs (padded to MAX_N = 64; fill unused slots with zero)
    receipt_hashes:   [[u8; 32]; MAX_N],
    nullifiers:       [[u8; 32]; MAX_N],
    adapters:         [[u8; 32]; MAX_N],
    amounts_in:       [u128; MAX_N],
    amounts_out:      [u128; MAX_N],
) {
    verify_receipts::<MAX_N>(
        n,
        accumulator_root,
        capability_hash,
        adapter_filter,
        min_return_bps,
        receipt_hashes,
        nullifiers,
        adapters,
        amounts_in,
        amounts_out,
    );
}
