// Binius64 Browser Prover — Demo harness
//
// Loads the WASM module from ../pkg/ and wires up the three circuit buttons.
// Serve with any static HTTP server, e.g.:
//   python3 -m http.server 8080 --directory .
//   npx serve .

import init, {
  prove_encumber,
  prove_spend,
  prove_settle,
  prover_version,
} from "../pkg/binius_wasm_prover.js";

// ── Init ──────────────────────────────────────────────────────────────────────

const statusBar = document.getElementById("status-bar");

async function boot() {
  try {
    await init();
    const v = prover_version();
    statusBar.className = "ready";
    statusBar.innerHTML = `<span class="dot"></span>Binius64 WASM prover ready — v${v} · portable GF(2¹²⁸) · no rayon (single-threaded)`;

    document.getElementById("enc-btn").disabled = false;
    document.getElementById("sp-btn").disabled = false;
    document.getElementById("se-btn").disabled = false;

    document.getElementById("enc-result").textContent = "Ready. Click the button to prove.";
    document.getElementById("sp-result").textContent  = "Ready. Click the button to prove.";
    document.getElementById("se-result").textContent  = "Ready. Click the button to prove.";
  } catch (e) {
    statusBar.innerHTML = `<span class="dot"></span>WASM init failed: ${e}`;
    console.error(e);
  }
}

boot();

// ── Helpers ───────────────────────────────────────────────────────────────────

function val(id) { return document.getElementById(id).value.trim(); }
function num(id) { return parseInt(document.getElementById(id).value, 10); }

function setResult(id, text, cls = "") {
  const el = document.getElementById(id);
  el.textContent = text;
  el.className = "result " + cls;
}

function setStats(id, elapsed_ms, size_kb) {
  document.getElementById(id).innerHTML =
    `<span>⏱ ${(elapsed_ms / 1000).toFixed(2)}s</span><span>📦 ${size_kb.toFixed(1)} KB</span>`;
}

async function runProver(btnId, resultId, statsId, label, fn, buildInput) {
  const btn = document.getElementById(btnId);
  btn.disabled = true;
  setResult(resultId, `Proving ${label}… (this may take 10–30 s in the browser)`, "pending");

  // Yield to the UI thread before starting heavy work
  await new Promise(r => setTimeout(r, 30));

  const t0 = performance.now();
  try {
    const input = buildInput();
    const result = fn(input);
    const elapsed = performance.now() - t0;
    setStats(statsId, elapsed, result.proof_size_kb);
    setResult(
      resultId,
      [
        `✓ ${label} proof verified`,
        ``,
        `proof_hex (first 64 chars):`,
        `  ${result.proof_hex.slice(0, 66)}…`,
        ``,
        `proof_size:  ${result.proof_size_kb.toFixed(1)} KB`,
        `prove_time:  ${(elapsed / 1000).toFixed(2)} s`,
        `public_inputs (${result.public_inputs.length} words):`,
        `  ${result.public_inputs.slice(0, 6).join("  ")}  …`,
      ].join("\n"),
      ""
    );
  } catch (e) {
    const elapsed = performance.now() - t0;
    setResult(resultId, `✗ Error after ${(elapsed/1000).toFixed(2)}s:\n${e}`, "error");
    console.error(e);
  } finally {
    btn.disabled = false;
  }
}

// ── Encumber ──────────────────────────────────────────────────────────────────

document.getElementById("enc-btn").addEventListener("click", () =>
  runProver("enc-btn", "enc-result", "enc-stats", "Encumber", prove_encumber, () => ({
    note_value:        num("enc-note-value"),
    note_rand:         val("enc-note-rand"),
    owner_pk:          val("enc-owner-pk"),
    collateral_amount: num("enc-collateral"),
    log_inv_rate:      num("enc-rate"),
  }))
);

// ── Spend ─────────────────────────────────────────────────────────────────────

document.getElementById("sp-btn").addEventListener("click", () =>
  runProver("sp-btn", "sp-result", "sp-stats", "Spend", prove_spend, () => ({
    in_value:     num("sp-in-value"),
    in_rand:      val("sp-in-rand"),
    in_pk:        val("sp-in-pk"),
    out_value:    num("sp-out-value"),
    out_rand:     val("sp-out-rand"),
    out_pk:       val("sp-out-pk"),
    log_inv_rate: num("sp-rate"),
  }))
);

// ── Settle ────────────────────────────────────────────────────────────────────

document.getElementById("se-btn").addEventListener("click", () =>
  runProver("se-btn", "se-result", "se-stats", "Settle", prove_settle, () => ({
    in_value:     num("se-in-value"),
    in_rand:      val("se-in-rand"),
    in_pk:        val("se-in-pk"),
    out_value:    num("se-out-value"),
    out_rand:     val("se-out-rand"),
    out_pk:       val("se-out-pk"),
    log_inv_rate: num("se-rate"),
  }))
);
