#!/usr/bin/env node
// SHA256SUMS üretir (LF-normalize: CRLF klonlar ve ham indirmeler aynı hash'i verir).
// Çalıştırma: npm run checksums  (dosya değişikliğinden SONRA, commit'ten ÖNCE)
// NOT: SHA256SUMS'un kendisi listeye dahil değildir.
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

const FILES = [
  "plugin/package.json",
  "plugin/index.ts",
  "plugin/rpc.ts",
  "plugin/tui.tsx",
  "scripts/install.sh",
  "scripts/install.ps1",
  "scripts/install.cmd",
];

const lines = FILES.map((f) => {
  const normalized = readFileSync(f, "utf8").replace(/\r\n/g, "\n");
  const hex = createHash("sha256").update(normalized, "utf8").digest("hex");
  return `${hex}  ${f}`;
});
writeFileSync("SHA256SUMS", lines.join("\n") + "\n");
console.log(`SHA256SUMS yazıldı (${FILES.length} dosya)`);
