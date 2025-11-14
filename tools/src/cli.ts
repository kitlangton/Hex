#!/usr/bin/env bun
/**
 * Hex CLI - command-line interface for Hex build tools
 */
import { Command, Options } from "@effect/cli"
import { NodeContext, NodeRuntime } from "@effect/platform-node"
import { Effect } from "effect"
import { versionCommand } from "./commands/version.js"
import { listCommand } from "./commands/list.js"
import { releaseCommand } from "./commands/release.js"
import { AllServicesLive } from "./layers/index.js"

// Global options that apply to all commands
const bucketOption = Options.text("bucket").pipe(
  Options.withDefault("hex-updates"),
  Options.withDescription("S3 bucket name")
)

const regionOption = Options.text("region").pipe(
  Options.withDefault("us-east-1"),
  Options.withDescription("AWS region")
)

const schemeOption = Options.text("scheme").pipe(
  Options.withDefault("Hex"),
  Options.withDescription("Xcode scheme")
)

const plistOption = Options.text("plist").pipe(
  Options.withDefault("Hex/Info.plist"),
  Options.withDescription("Path to Info.plist")
)

const exportOptionsOption = Options.text("export-options").pipe(
  Options.withDefault("ExportOptions.plist"),
  Options.withDescription("Path to ExportOptions.plist")
)

// Combine all global options
const globalOptions = {
  bucket: bucketOption,
  region: regionOption,
  scheme: schemeOption,
  plist: plistOption,
  exportOptions: exportOptionsOption,
}

// Root command with subcommands
const hexCommand = Command.make("hex", globalOptions, (globalOpts) =>
  Effect.gen(function* () {
    // This handler runs for the parent command
    yield* Effect.log("Use a subcommand: version, list, or release")
    yield* Effect.log("Run 'hex --help' for more information")
  })
).pipe(
  Command.withSubcommands([versionCommand, listCommand, releaseCommand]),
  Command.withDescription("Hex build and release tools")
)

// CLI application
const cli = Command.run(hexCommand, {
  name: "hex",
  version: "1.0.0",
})

// Run the CLI with all layers provided at the top
cli(process.argv).pipe(
  Effect.provide(AllServicesLive),
  Effect.provide(NodeContext.layer),
  Effect.catchAll((error) =>
    Effect.sync(() => {
      console.error("Error:", error)
      process.exit(1)
    })
  ),
  NodeRuntime.runMain
)
