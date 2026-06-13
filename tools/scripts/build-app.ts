#!/usr/bin/env bun
/**
 * Build the Hex macOS app from the command line.
 *
 * Usage:
 *   bun run build              # Debug build into build/DerivedData
 *   bun run build --release    # Release configuration
 *   bun run build --run        # build, then (re)launch the app
 *
 * Notes:
 *  - `-skipMacroValidation` is required: the SPM macro plugins (TCA, Dependencies,
 *    CasePaths, Perception) are otherwise rejected as "must be enabled" on the CLI.
 *  - `-allowProvisioningUpdates` lets xcodebuild resolve the signing identity from the
 *    project's DEVELOPMENT_TEAM without manual provisioning.
 *  - A project-local derivedDataPath keeps the signed .app next to the repo and avoids
 *    the "Hex Debug 2/3.app" duplicates LaunchServices spawns in the shared DerivedData.
 */

import { spawnSync } from "child_process";
import { existsSync, rmSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(scriptDir, "..", "..");
const args = process.argv.slice(2);
const release = args.includes("--release");
const run = args.includes("--run");
const configuration = release ? "Release" : "Debug";
const derivedData = join(repoRoot, "build", "DerivedData");
const productsDir = join(derivedData, "Build", "Products", configuration);

function sh(cmd: string, cmdArgs: string[]): void {
  const res = spawnSync(cmd, cmdArgs, { cwd: repoRoot, stdio: "inherit" });
  if (res.status !== 0) process.exit(res.status ?? 1);
}

// Stale numbered copies fragment TCC grants (Input Monitoring etc.) — clear them first.
for (const suffix of [" 2", " 3", " 4"]) {
  const dup = join(productsDir, `Hex Debug${suffix}.app`);
  if (existsSync(dup)) rmSync(dup, { recursive: true, force: true });
}

console.log(`Building Hex (${configuration})…`);
sh("xcodebuild", [
  "-project", "Hex.xcodeproj",
  "-scheme", "Hex",
  "-configuration", configuration,
  "-derivedDataPath", derivedData,
  "-skipMacroValidation",
  "-allowProvisioningUpdates",
  "build",
]);

const appName = release ? "Hex.app" : "Hex Debug.app";
const appPath = join(productsDir, appName);
console.log(`\n✅ Built ${appPath}`);

if (run) {
  console.log("Relaunching…");
  spawnSync("pkill", ["-f", appName.replace(".app", "")], { stdio: "ignore" });
  sh("open", [appPath]);
}
