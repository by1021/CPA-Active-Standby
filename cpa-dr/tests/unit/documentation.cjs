"use strict";

// Source-only check: local Markdown links and preserved Cloudflare Worker code.
const fs = require("node:fs");
const path = require("node:path");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const root = path.resolve(__dirname, "../../..");
function markdownFiles(directory) {
  return fs.readdirSync(directory, {withFileTypes: true}).flatMap(entry => {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) return markdownFiles(file);
    return entry.isFile() && file.endsWith(".md") ? [file] : [];
  });
}
const files = [path.join(root, "README.md"), path.join(root, "cpa-dr/README.md"),
  path.join(root, "cpa-dr/ARCHITECTURE.md"), ...markdownFiles(path.join(root, "docs"))];
const errors = [];
for (const file of files) {
  const markdown = fs.readFileSync(file, "utf8");
  for (const match of markdown.matchAll(/!?\[[^\]\n]*\]\(([^\s)]+)(?:\s+"[^"]*")?\)/g)) {
    let target = match[1].replace(/^<|>$/g, "");
    if (/^(?:https?:|mailto:|data:|#)/i.test(target)) continue;
    target = decodeURIComponent(target.split("#")[0]);
    if (!target || /[{}]/.test(target)) continue;
    if (!fs.existsSync(path.resolve(path.dirname(file), target))) {
      errors.push(`${path.relative(root, file)}: ${target}`);
    }
  }
}
assert.deepEqual(errors, [], "broken local Markdown links");
const guides = files.filter(file => /Worker-KV.*操作手册/.test(file));
assert.equal(guides.length, 2, "preserve both Cloudflare guides");
function workerCode(file) {
  const markdown = fs.readFileSync(file, "utf8");
  return [...markdown.matchAll(/```(?:javascript|js)\n([\s\S]*?)\n```/g)].map(match => match[1]);
}
assert.ok(workerCode(guides[0]).length > 0, "Cloudflare Worker code remains documented");
assert.deepEqual(workerCode(guides[0]), workerCode(guides[1]), "both Worker snippets must remain equal");
// Original Worker code from source baseline e645357, not merely two matching edits.
assert.equal(crypto.createHash("sha256").update(JSON.stringify(workerCode(guides[0]))).digest("hex"),
  "018b64d1e225846d5aa5a32a6241b6b592840f1c952e57fcbe740701da736161",
  "Cloudflare Worker code must remain byte-identical to the approved baseline");
console.log(`PASS: ${files.length} Markdown files have valid local links; Cloudflare Worker snippets preserved`);
