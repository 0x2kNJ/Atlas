// cmd/prove runs the PLONK prover for a batch of binius64 proofs.
//
// Usage:
//
//	go run ./cmd/prove \
//	  --pk ./keys/pk.bin \
//	  --ccs ./keys/ccs.bin \
//	  --proofs-dir ./batch_proofs \
//	  --out ./batch.plonk
//
// Input files in proofs-dir: proof_0.bin, proof_1.bin, ... proof_{N-1}.bin
// where N matches the batch size the keys were compiled for.
//
// Output: a single PLONK proof (batch.plonk) that proves all N binius64
// proofs were correctly verified in-circuit.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/backend/plonk"
	"github.com/consensys/gnark/frontend"
	"github.com/consensys/gnark/frontend/cs/scs"

	binius "github.com/envelopes/binius-groth16-wrapper/circuit"
	"github.com/envelopes/binius-groth16-wrapper/aggregator"
)

func main() {
	pkPath := flag.String("pk", "./keys/pk.bin", "path to PLONK proving key")
	ccsPath := flag.String("ccs", "./keys/ccs.bin", "path to compiled constraint system")
	proofsDir := flag.String("proofs-dir", "./batch_proofs", "directory containing proof_N.bin files")
	outPath := flag.String("out", "./batch.plonk", "output path for the PLONK proof")
	metaPath := flag.String("meta", "./batch_meta.json", "output path for batch metadata JSON")
	flag.Parse()

	fmt.Println("=== Binius64 PLONK Batch Prover ===")

	// Step 1: Load the constraint system.
	fmt.Printf("[1/5] Loading constraint system from %s... ", *ccsPath)
	t0 := time.Now()
	ccs := plonk.NewCS(ecc.BN254)
	if err := loadKey(*ccsPath, ccs); err != nil {
		fmt.Fprintf(os.Stderr, "\nload ccs: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("done in %s\n", time.Since(t0).Round(time.Millisecond))

	// Step 2: Load the proving key.
	fmt.Printf("[2/5] Loading proving key from %s... ", *pkPath)
	t0 = time.Now()
	pk := plonk.NewProvingKey(ecc.BN254)
	if err := loadKey(*pkPath, pk); err != nil {
		fmt.Fprintf(os.Stderr, "\nload pk: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("done in %s\n", time.Since(t0).Round(time.Millisecond))

	// Step 3: Parse binius64 proofs from proofs-dir and build circuit assignment.
	fmt.Printf("[3/5] Parsing binius64 proofs and building witness... ")
	t0 = time.Now()
	batchSize := binius.DefaultBatchSize
	assignment, batchMeta, err := aggregator.BuildWitness(*proofsDir, batchSize)
	if err != nil {
		fmt.Fprintf(os.Stderr, "\nbuild witness: %v\n", err)
		os.Exit(1)
	}

	// Build the circuit template for witness compilation.
	circuit := binius.NewBatchVerifierCircuit(batchSize)
	_ = circuit // used implicitly by scs.NewBuilder below

	w, err := frontend.NewWitness(assignment, ecc.BN254.ScalarField())
	if err != nil {
		fmt.Fprintf(os.Stderr, "\nnew witness: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("done in %s\n", time.Since(t0).Round(time.Millisecond))

	// Step 4: Run PLONK prover.
	fmt.Printf("[4/5] Running PLONK prover... ")
	t0 = time.Now()
	proof, err := plonk.Prove(ccs, pk, w)
	if err != nil {
		fmt.Fprintf(os.Stderr, "\nprove: %v\n", err)
		os.Exit(1)
	}
	provingTime := time.Since(t0)
	fmt.Printf("done in %s\n", provingTime.Round(time.Second))

	// Step 5: Write proof and metadata.
	fmt.Printf("[5/5] Writing proof and metadata... ")
	t0 = time.Now()
	if err := writeKey(*outPath, proof); err != nil {
		fmt.Fprintf(os.Stderr, "\nwrite proof: %v\n", err)
		os.Exit(1)
	}

	batchMeta.ProvingTimeMs = provingTime.Milliseconds()
	metaJSON, _ := json.MarshalIndent(batchMeta, "", "  ")
	if err := os.WriteFile(*metaPath, metaJSON, 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "\nwrite meta: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("done in %s\n", time.Since(t0).Round(time.Millisecond))

	fmt.Println()
	fmt.Printf("✓  Batch proof written to %s\n", *outPath)
	fmt.Printf("   Batch size: %d proofs\n", batchSize)
	fmt.Printf("   Proving time: %s\n", provingTime.Round(time.Second))
	fmt.Printf("   On-chain gas (estimated): ~350,000\n")
	fmt.Printf("   Amortised gas per proof: ~%d\n", 350_000/batchSize)

	_ = scs.NewBuilder // suppress unused import
}

// loadKey is a helper that deserialises a gnark key from a file.
func loadKey(path string, obj interface{ ReadFrom(r io.Reader) (int64, error) }) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = obj.ReadFrom(f)
	return err
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
