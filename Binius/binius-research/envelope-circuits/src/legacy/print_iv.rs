use sha2::{Sha256, Digest, compress256};
use digest::core_api::Block;

fn main() {
    let hash = Sha256::digest(b"BINIUS SHA-256 COMPRESS");
    let bytes: &[u8] = hash.as_ref();

    println!("SHA256('BINIUS SHA-256 COMPRESS') = {}", hex::encode(bytes));

    let mut state = [0u32; 8];
    for i in 0..8 {
        state[i] = u32::from_le_bytes([bytes[i*4], bytes[i*4+1], bytes[i*4+2], bytes[i*4+3]]);
    }

    println!("\nInitial state [u32; 8] (LE interpretation):");
    for (i, s) in state.iter().enumerate() {
        println!("  H[{}] = 0x{:08x}", i, s);
    }

    // Convert state back to bytes the same way binius does (LE cast)
    let state_bytes: [u8; 32] = unsafe { std::mem::transmute(state) };
    println!("\nState as LE bytes: {}", hex::encode(&state_bytes));

    // Test compression: compress(IV, [zeros; 64])
    let mut ret = state;
    let block = Block::<Sha256>::default();
    compress256(&mut ret, &[block]);
    let output: [u8; 32] = unsafe { std::mem::transmute(ret) };
    println!("\nCompression of all-zeros block:");
    println!("  hex: {}", hex::encode(&output));

    // Test: compress(IV, [left || right]) where left=right=SHA256("")
    let empty_hash = Sha256::digest(b"");
    let mut block_data = [0u8; 64];
    block_data[..32].copy_from_slice(&empty_hash);
    block_data[32..].copy_from_slice(&empty_hash);

    let mut ret2 = state;
    let block2: Block<Sha256> = *Block::<Sha256>::from_slice(&block_data);
    compress256(&mut ret2, &[block2]);
    let output2: [u8; 32] = unsafe { std::mem::transmute(ret2) };
    println!("\nCompression of [SHA256('') || SHA256('')]:");
    println!("  hex: {}", hex::encode(&output2));

    // Compare with full SHA256(left || right)
    let full_hash = Sha256::digest(&block_data);
    println!("\nFull SHA256([SHA256('') || SHA256('')]):");
    println!("  hex: {}", hex::encode(&full_hash));

    println!("\n(These should differ since compression != full hash)");
}
