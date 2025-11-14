/**
 * Version command - get current version info
 */
import { Command } from "@effect/cli"
import { Effect } from "effect"
import { VersionManager } from "../services/VersionManager.js"

export const versionCommand = Command.make("version", {}, () =>
  Effect.gen(function* () {
    const vm = yield* VersionManager
    const info = yield* vm.getVersionInfo

    yield* Effect.log(`Version: ${info.version}`)
    yield* Effect.log(`Build: ${info.buildNumber}`)
  })
).pipe(Command.withDescription("Show current version and build number"))
