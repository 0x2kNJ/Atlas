/**
 * Atlas Protocol — Binius64 Proof API Server
 *
 * Lightweight HTTP server that wraps the Rust compliance-service binary.
 * The UI calls POST /api/prove with receipt data; this server spawns the
 * binary, pipes JSON through stdin/stdout, and returns the result.
 *
 * Also serves as the attestation signer for the demo (Anvil account 1).
 *
 * Usage:
 *   node proof-server.mjs          # starts on port 3001
 *   PROOF_PORT=4000 node proof-server.mjs
 */

import { createServer } from "node:http";
import { execFile } from "node:child_process";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const BINARY = resolve(__dirname, "../Binius/binius64-compliance/target/release/compliance-service");
const PORT = parseInt(process.env.PROOF_PORT || "3001", 10);

function runProver(jsonInput) {
  return new Promise((resolve, reject) => {
    const child = execFile(BINARY, [], { maxBuffer: 10 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err) {
        reject(new Error(`Prover failed: ${stderr || err.message}`));
        return;
      }
      try {
        resolve(JSON.parse(stdout));
      } catch {
        reject(new Error(`Invalid prover output: ${stdout.slice(0, 200)}`));
      }
    });
    child.stdin.write(jsonInput);
    child.stdin.end();
  });
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks).toString()));
    req.on("error", reject);
  });
}

const server = createServer(async (req, res) => {
  // CORS for local Vite dev server
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");

  if (req.method === "OPTIONS") {
    res.writeHead(204);
    res.end();
    return;
  }

  if (req.method === "POST" && req.url === "/api/prove") {
    try {
      const body = await readBody(req);
      const result = await runProver(body);
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(result));
    } catch (e) {
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ success: false, error: e.message }));
    }
    return;
  }

  res.writeHead(404);
  res.end("Not found");
});

server.listen(PORT, () => {
  console.log(`Binius64 proof server listening on http://localhost:${PORT}`);
  console.log(`Binary: ${BINARY}`);
});
