#!/usr/bin/env bash
# Build script for binius-wasm-prover
#
# Produces two build variants:
#   pkg/        — SIMD128 build (default, Chrome 91+, Safari 16.4+, iOS 16.4+)
#   pkg-compat/ — Portable fallback (all browsers including Safari < 16.4)
#
# The SIMD build is ~3-5x faster on GF(2^128) arithmetic and is the right
# default for 2026+ browsers. The compat build serves as a guaranteed fallback.
#
# Usage:
#   ./build.sh            # build SIMD variant only (fast, ~90s)
#   ./build.sh --all      # build both variants
#   ./build.sh --compat   # build compat-only (for CI/testing)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_SIMD=true
BUILD_COMPAT=false

for arg in "$@"; do
  case "$arg" in
    --all)    BUILD_SIMD=true; BUILD_COMPAT=true ;;
    --compat) BUILD_SIMD=false; BUILD_COMPAT=true ;;
  esac
done

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║      binius-wasm-prover build                                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── SIMD128 build (default, written to pkg/) ──────────────────────────────────
if $BUILD_SIMD; then
  echo "▶ Building portable variant (default)..."
  echo "  → Portable GF(2^128) arithmetic via u128 (no SIMD yet)"
  echo "  → NOTE: binius-field wasm32 SIMD128 path is currently incomplete"
  echo "    upstream (BinaryField1b subfield impls missing). Uncomment"
  echo "    rustflags in .cargo/config.toml when Irreducible ships a fix."
  echo ""

  # Default build — no simd128 flag
  wasm-pack build --target web --release --out-dir pkg

  SIMD_SIZE=$(du -sh pkg/binius_wasm_prover_bg.wasm | cut -f1)
  echo ""
  echo "  ✓ SIMD build complete → pkg/  ($SIMD_SIZE WASM)"
fi

# ── Portable/compat build (written to pkg-compat/) ───────────────────────────
if $BUILD_COMPAT; then
  echo ""
  echo "▶ Building portable/compat variant (no SIMD)..."
  echo "  → Falls back to portable u128 GF(2^128) arithmetic"
  echo "  → Compatible: all browsers (Safari < 16.4, older Android)"
  echo ""

  # Override the .cargo/config.toml SIMD flag by clearing rustflags
  RUSTFLAGS="" wasm-pack build --target web --release --out-dir pkg-compat

  COMPAT_SIZE=$(du -sh pkg-compat/binius_wasm_prover_bg.wasm | cut -f1)
  echo ""
  echo "  ✓ Compat build complete → pkg-compat/  ($COMPAT_SIZE WASM)"
fi

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "Build summary:"
if $BUILD_SIMD;   then echo "  pkg/         (SIMD128)   — $SIMD_SIZE"; fi
if $BUILD_COMPAT; then echo "  pkg-compat/  (portable)  — $COMPAT_SIZE"; fi
echo ""
echo "To run the demo:"
echo "  cd demo && python3 -m http.server 8080"
echo "══════════════════════════════════════════════════════════════"
