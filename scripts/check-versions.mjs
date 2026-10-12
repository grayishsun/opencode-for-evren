#!/usr/bin/env node
// Sürüm tekilleştirme denetimi: 4 konumdaki sürüm birebir aynı olmalı.
//   package.json, plugin/package.json, scripts/install.sh, scripts/install.ps1
// Çalıştırma: npm run check-versions
import { readFileSync } from "node:fs";

const want = new Map([
  ["package.json", JSON.parse(readFileSync("package.json", "utf8")).version],
  ["plugin/package.json", JSON.parse(readFileSync("plugin/package.json", "utf8")).version],
  ["scripts/install.sh", readFileSync("scripts/install.sh", "utf8").match(/^INSTALLER_VERSION="([^"]+)"/m)?.[1]],
  ["scripts/install.ps1", readFileSync("scripts/install.ps1", "utf8").match(/^\$InstallerVersion = "([^"]+)"/m)?.[1]],
]);

let failed = false;
for (const [file, version] of want) {
  console.log(`${version ?? "(BULUNAMADI)"}\t${file}`);
  if (!version) failed = true;
}
const unique = [...new Set(want.values())];
if (unique.length !== 1) {
  console.error(`SÜRÜM UYUŞMAZLIĞI: ${unique.join(", ")}`);
  failed = true;
}
if (failed) process.exit(1);
console.log(`OK: hepsi ${unique[0]}`);
