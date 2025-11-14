/**
 * List command - list available versions in S3
 */
import { Command, Options } from "@effect/cli"
import { Effect } from "effect"
import { S3 } from "../services/S3.js"

const prefixOption = Options.text("prefix").pipe(
  Options.withDefault("Hex-"),
  Options.withDescription("Filter by prefix")
)

export const listCommand = Command.make(
  "list",
  { prefix: prefixOption },
  ({ prefix }) =>
  Effect.gen(function* () {
    const s3 = yield* S3
    const versions = yield* s3.listVersions(prefix)

    if (versions.length === 0) {
      yield* Effect.log("No versions found")
      return
    }

    yield* Effect.log(`Found ${versions.length} version(s):\n`)

    for (const v of versions) {
      const sizeMB = (v.size / 1024 / 1024).toFixed(2)
      const date = v.lastModified.toISOString().split("T")[0]
      yield* Effect.log(`  ${v.key}`)
      yield* Effect.log(`    Size: ${sizeMB} MB`)
      yield* Effect.log(`    Modified: ${date}`)
      yield* Effect.log(`    URL: ${yield* Effect.sync(() => s3.getUrl(v.key))}`)
      yield* Effect.log("")
    }
  })
).pipe(Command.withDescription("List available versions in S3"))
