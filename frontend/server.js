// ═══════════════════════════════════════════════════════════════════════
// server.js — Minimal static file server for the CSI ORIGIN frontend
// Run: node frontend/server.js
// ═══════════════════════════════════════════════════════════════════════

const http = require("http");
const fs   = require("fs");
const path = require("path");

const PORT = 3000;
const DIR  = __dirname;

const MIME = {
  ".html": "text/html",
  ".css":  "text/css",
  ".js":   "application/javascript",
  ".json": "application/json",
  ".png":  "image/png",
  ".svg":  "image/svg+xml",
  ".ico":  "image/x-icon",
};

const server = http.createServer((req, res) => {
  let filePath = path.join(DIR, req.url === "/" ? "index.html" : req.url);
  const ext = path.extname(filePath).toLowerCase();

  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404, { "Content-Type": "text/plain" });
      res.end("404 Not Found");
      return;
    }
    res.writeHead(200, {
      "Content-Type": MIME[ext] || "application/octet-stream",
      "Access-Control-Allow-Origin": "*",
    });
    res.end(data);
  });
});

server.listen(PORT, () => {
  console.log(`\n  ⚡ CSI ORIGIN Frontend`);
  console.log(`  ─────────────────────`);
  console.log(`  http://localhost:${PORT}\n`);
  console.log(`  Ensure Anvil is running on http://127.0.0.1:8545`);
  console.log(`  and contracts are deployed via Deploy.s.sol\n`);
});
