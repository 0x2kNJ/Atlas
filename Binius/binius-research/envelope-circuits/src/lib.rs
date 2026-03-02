// Atlas Protocol — Binius m3 Envelope Circuits
//
// Ported from the legacy binius-frontend API to the current upstream binius_m3 API.
//
// The m3 API uses a table-based model:
//   1. Define a ConstraintSystem
//   2. Add tables with columns and gadgets
//   3. Fill events (witness rows) into the table
//   4. Compile, prove, verify
//
// Each SHA-256 "event" is a 512-bit message block ([u32; 16]).
// The compliance circuit chains N SHA-256 compressions.

pub mod compliance;
