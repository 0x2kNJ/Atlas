// cmd/setup generates the PLONK proving key and verification key for the
// BatchBiniusVerifier circuit and writes them to disk.
//
// Usage:
//
//	go run ./cmd/setup [--batch-size N] [--out-dir ./keys]
//
// This is a one-time operation.  The proving key (pk.bin) is used by the
// aggregator prover.  The verification key (vk.bin) is used both by the
// aggregator and to export the Solidity verifier (see cmd/export).
//
// Powers-of-tau SRS: the setup automatically uses an unsafe deterministic SRS
// for testing.  In production, replace with a real ceremony SRS loaded from
// disk (e.g. Hermez perpetual powers of tau, https://github.com/iden3/snarkjs).
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/backend/plonk"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/frontend/cs/scs"
	"github.com/consensys/gnark/test/unsafekzg"

	binius "github.com/envelopes/binius-groth16-wrapper/circuit"
)

func main() {
	batchSize := flag.Int("batch-size", binius.DefaultBatchSize, "number of binius64 proofs per PLONK proof")
	outDir := flag.String("out-dir", "./keys", "directory to write pk.bin, vk.bin, ccs.bin")
	flag.Parse()

	if err := os.MkdirAll(*outDir, 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "mkdir: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("=== Binius64 Groth16-Wrapper PLONK Setup ===\n")
	fmt.Printf("  batch size : %d proofs\n", *batchSize)
	fmt.Printf("  FRI queries: %d\n", binius.NumFRIQueries)
	fmt.Printf("  Merkle depth: %d\n", binius.MerkleDepth)
	fmt.Println()

	// Step 1: Compile circuit → constraint system.
	fmt.Printf("[1/4] Compiling circuit... ")
	t0 := time.Now()
	circuit := binius.NewBatchVerifierCircuit(*batchSize)
	ccs, err := frontend.Compile(ecc.BN254.ScalarField(), scs.NewBuilder, circuit)
	if err != nil {
		fmt.Fprintf(os.Stderr, "\ncompile error: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("done in %s  (%d constraints)\n", time.Since(t0).Round(time.Millisecond), ccs.GetNbConstraints())

	// Step 2: Build SRS.
	// WARNING: unsafekzg is NOT secure.  Replace with a real ceremony SRS in production.
	fmt.Printf("[2/4] Building SRS (unsafe/test — replace for production)... ")
	t0 = time.Now()
	srs, srsLagrange, err := unsafekzg.NewSRS(ccs)
	if err != nil {
		fmt.Fprintf(os.Stderr, "\nSRS error: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("done in %s\n", time.Since(t0).Round(time.Millisecond))

	// Step 3: Run PLONK setup to produce pk, vk.
	fmt.Printf("[3/4] Running PLONK setup... ")
	t0 = time.Now()
	pk, vk, err := plonk.Setup(ccs, srs, srsLagrange)
	if err != nil {
		fmt.Fprintf(os.Stderr, "\nsetup error: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("done in %s\n", time.Since(t0).Round(time.Millisecond))

	// Step 4: Write keys to disk.
	fmt.Printf("[4/4] Writing keys to %s... ", *outDir)
	t0 = time.Now()
	if err := writeKey(*outDir+"/pk.bin", pk); err != nil {
		fmt.Fprintf(os.Stderr, "\nwrite pk: %v\n", err)
		os.Exit(1)
	}
	if err := writeKey(*outDir+"/vk.bin", vk); err != nil {
		fmt.Fprintf(os.Stderr, "\nwrite vk: %v\n", err)
		os.Exit(1)
	}
	if err := writeKey(*outDir+"/ccs.bin", ccs); err != nil {
		fmt.Fprintf(os.Stderr, "\nwrite ccs: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("done in %s\n", time.Since(t0).Round(time.Millisecond))

	fmt.Println()
	fmt.Printf("✓  Setup complete.\n")
	fmt.Printf("   pk.bin  → aggregator prover (keep secret)\n")
	fmt.Printf("   vk.bin  → run cmd/export to produce Verifier.sol\n")
	fmt.Printf("   ccs.bin → used by cmd/prove at witness-generation time\n")
}

// writeKey is a helper that serialises any gnark io.WriterRawTo to a file.
func writeKey(path string, obj interface{ WriteTo(w io.Writer) (int64, error) }) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = obj.WriteTo(f)
	return err
}
