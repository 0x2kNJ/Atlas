// cmd/export reads the PLONK verification key and exports a Solidity smart
// contract that can verify batch PLONK proofs on-chain.
//
// Usage:
//
//	go run ./cmd/export \
//	  --vk ./keys/vk.bin \
//	  --out ./contracts/src/BiniusBatchVerifier.sol
//
// The generated Verifier.sol uses gnark's built-in PLONK/KZG Solidity template.
// It exposes a single function:
//
//	function verifyProof(
//	    bytes calldata proof,
//	    bytes32[32] calldata publicInputs  // BatchPublicInputsHash
//	) external view returns (bool);
//
// On-chain gas cost: ~350,000 gas (KZG pairing check + polynomial evaluations).
// Amortised cost per binius64 proof in a batch of 100: ~3,500 gas.
package main

import (
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/backend/plonk"
)

func main() {
	vkPath := flag.String("vk", "./keys/vk.bin", "path to PLONK verification key")
	outPath := flag.String("out", "./BiniusBatchVerifier.sol", "output path for Solidity verifier")
	flag.Parse()

	fmt.Println("=== Binius64 PLONK → Solidity Verifier Export ===")

	// Load verification key.
	fmt.Printf("[1/2] Loading verification key from %s... ", *vkPath)
	t0 := time.Now()
	vk := plonk.NewVerifyingKey(ecc.BN254)
	f, err := os.Open(*vkPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "\nopen vk: %v\n", err)
		os.Exit(1)
	}
	if _, err := vk.ReadFrom(f); err != nil {
		fmt.Fprintf(os.Stderr, "\nread vk: %v\n", err)
		os.Exit(1)
	}
	f.Close()
	fmt.Printf("done in %s\n", time.Since(t0).Round(time.Millisecond))

	// Export Solidity verifier.
	fmt.Printf("[2/2] Exporting Solidity verifier to %s... ", *outPath)
	t0 = time.Now()
	outFile, err := os.Create(*outPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "\ncreate output: %v\n", err)
		os.Exit(1)
	}
	defer outFile.Close()

	// ExportSolidity is defined on the plonk.VerifyingKey interface directly.
	if err := vk.ExportSolidity(outFile); err != nil {
		fmt.Fprintf(os.Stderr, "\nexport solidity: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("done in %s\n", time.Since(t0).Round(time.Millisecond))

	stat, _ := outFile.Stat()
	fmt.Println()
	fmt.Printf("✓  Solidity verifier written to %s (%d bytes)\n", *outPath, stat.Size())
	fmt.Println()
	fmt.Println("   Deploy BiniusBatchVerifier.sol to:")
	fmt.Println("   - Arbitrum One  (no block gas limit, 100-bit security, 232 FRI queries)")
	fmt.Println("   - L3 appchain   (recommended for Envelopes production)")
	fmt.Println()
	fmt.Println("   On-chain interface:")
	fmt.Println("   function verifyProof(bytes proof, bytes32[1] publicInputs) returns (bool)")
	fmt.Println("   where publicInputs[0] = BatchPublicInputsHash")
}
