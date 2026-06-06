// Headless Mermaid diagram validator.
//
// Parses every ```mermaid fenced block under the given root (default: docs/)
// using the real Mermaid parser, so a syntactically broken diagram cannot reach
// a published doc. Parse-only: no rendering, no Chromium — just mermaid + a
// minimal jsdom DOM. Exits non-zero (and lists every failure) if any block fails.
//
// LIMITATION: this catches *syntax* errors, not *render/layout* errors. A diagram
// can parse cleanly yet crash the renderer (e.g. GitHub). Full render validation
// needs a real browser (mermaid-cli + Chromium). As a partial mitigation we add a
// static heuristic for the most common C4 render crash (Rel-to-boundary) below.
//
// Usage:  node validate.mjs [root-dir]
// Wired into scripts/pre-deploy. Run standalone with: npm run validate
//
// Why full `mermaid` and not `@mermaid-js/parser`: the standalone parser only
// covers a few diagram types; sequence/flowchart/C4/ER (what these docs use)
// still go through mermaid's bundled parsers, reachable only via mermaid.parse().

import { JSDOM } from "jsdom";
import fs from "node:fs";
import path from "node:path";

const root = process.argv[2] || "docs";

// Mermaid expects a browser-like global environment even for parse-only use.
const dom = new JSDOM("<!DOCTYPE html><body></body>", { pretendToBeVisual: true });
globalThis.window = dom.window;
globalThis.document = dom.window.document;

const mermaid = (await import("mermaid")).default;
mermaid.initialize({ startOnLoad: false, securityLevel: "loose" });

function walk(dir, out) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(p, out);
    else if (entry.name.endsWith(".md")) out.push(p);
  }
}

function extractBlocks(file) {
  const lines = fs.readFileSync(file, "utf8").split("\n");
  const blocks = [];
  let i = 0;
  while (i < lines.length) {
    if (lines[i].trim() === "```mermaid") {
      const start = i + 1; // 1-based line of ```mermaid fence
      const body = [];
      i++;
      while (i < lines.length && lines[i].trim() !== "```") {
        body.push(lines[i]);
        i++;
      }
      blocks.push({ start, body });
    }
    i++;
  }
  return blocks;
}

// Heuristic: catch the most common C4 *render* crash that parse() does NOT —
// a Rel() whose endpoint is a boundary/Deployment_Node has no x/y coordinate,
// so mermaid's C4 layout throws "Cannot read properties of undefined (reading 'x')".
// parse() accepts it; only rendering fails. We can't render headlessly (needs a
// browser), but we can flag this class statically.
function c4BoundaryRelIssues(body) {
  const first = (body.find((l) => l.trim()) || "").trim();
  if (!/^C4(Context|Container|Component|Deployment|Dynamic)\b/.test(first)) return [];
  const boundaries = new Set();
  const boundaryRe = /\b(?:Deployment_Node|System_Boundary|Container_Boundary|Enterprise_Boundary|Boundary|Node)\(\s*([A-Za-z0-9_]+)/g;
  for (const line of body) {
    let m;
    while ((m = boundaryRe.exec(line))) boundaries.add(m[1]);
  }
  const issues = [];
  const relRe = /\b(?:Rel|BiRel)(?:_[UDLR]+)?\(\s*([A-Za-z0-9_]+)\s*,\s*([A-Za-z0-9_]+)/;
  body.forEach((line, idx) => {
    const r = relRe.exec(line.trim());
    if (!r) return;
    for (const alias of [r[1], r[2]]) {
      if (boundaries.has(alias)) {
        issues.push({ idx, alias, line: line.trim() });
      }
    }
  });
  return issues;
}

if (!fs.existsSync(root)) {
  console.error(`mermaid-validate: root not found: ${root}`);
  process.exit(2);
}

const files = [];
walk(root, files);

let total = 0;
const failures = [];

for (const file of files) {
  for (const { start, body } of extractBlocks(file)) {
    total++;
    const code = body.join("\n");
    for (const iss of c4BoundaryRelIssues(body)) {
      failures.push({
        file,
        fileLine: start + iss.idx + 1,
        summary: `C4 Rel endpoint '${iss.alias}' is a boundary/Deployment_Node — renders crash with "reading 'x'". Point Rel at a leaf Container instead.`,
        offending: iss.line,
      });
    }
    try {
      await mermaid.parse(code);
    } catch (e) {
      const lines = String(e?.message ?? e).split("\n");
      const summary =
        lines.find((l) => /Expecting|Lexical|got |No diagram type/.test(l)) ||
        lines[0] ||
        "parse error";
      const m = /line (\d+)/.exec(String(e?.message ?? ""));
      const diagLine = m ? parseInt(m[1], 10) : null;
      const fileLine = diagLine ? start + diagLine : start; // fence + offset
      const offending = diagLine ? (body[diagLine - 1] || "").trim() : "";
      failures.push({ file, fileLine, summary: summary.trim().slice(0, 160), offending });
    }
  }
}

if (failures.length) {
  console.error(`\nMermaid validation FAILED — ${failures.length}/${total} block(s) broken:\n`);
  for (const f of failures) {
    console.error(`  ${f.file}:${f.fileLine}`);
    console.error(`    ${f.summary}`);
    if (f.offending) console.error(`    offending> ${f.offending}`);
  }
  console.error(
    `\nTip: a ';' in sequenceDiagram message/Note text is a statement separator — use ',' instead.`,
  );
  process.exit(1);
}

console.log(`Mermaid OK — ${total} diagram block(s) across ${files.length} doc(s) parse clean.`);
