#!/usr/bin/env bun
/**
 * Non-interactive changeset creator for AI agents
 * 
 * Usage:
 *   bun run tools/scripts/add-changeset.ts <type> <summary>
 * 
 * Example:
 *   bun run tools/scripts/add-changeset.ts patch "Fix clipboard timing"
 *   bun run tools/scripts/add-changeset.ts minor "Add new feature"
 */

import { writeFileSync } from "fs";
import { randomBytes } from "crypto";

const args = process.argv.slice(2);

if (args.length < 2) {
  console.error("Usage: add-changeset.ts <type> <summary>");
  console.error("  type: patch | minor | major");
  console.error("  summary: Description of the change");
  process.exit(1);
}

const [type, ...summaryParts] = args;
const summary = summaryParts.join(" ");

if (!["patch", "minor", "major"].includes(type)) {
  console.error(`Invalid type: ${type}. Must be patch, minor, or major.`);
  process.exit(1);
}

if (!summary.trim()) {
  console.error("Summary cannot be empty");
  process.exit(1);
}

// Generate random filename (like changeset does)
const id = randomBytes(4).toString("hex");
const filename = `.changeset/${id}.md`;

const content = `---
"hex-app": ${type}
---

${summary.trim()}
`;

writeFileSync(filename, content);
console.log(`✓ Created changeset: ${filename}`);
console.log(`  Type: ${type}`);
console.log(`  Summary: ${summary}`);
