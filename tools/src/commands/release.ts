/**
 * Release command - full release pipeline
 */
import { Command, Options } from "@effect/cli"
import { Effect } from "effect"
import { Path, FileSystem } from "@effect/platform"
import { S3 } from "../services/S3.js"
import { VersionManager } from "../services/VersionManager.js"
import { XcodeBuild } from "../services/XcodeBuild.js"
import { CodeSign } from "../services/CodeSign.js"

const bumpOption = Options.choice("bump", ["major", "minor", "patch"] as const).pipe(
  Options.withDefault("patch" as const),
  Options.withDescription("Version bump type")
)

export const releaseCommand = Command.make("release", { bump: bumpOption }, ({ bump }) =>
  Effect.gen(function* () {
    const s3 = yield* S3
    const vm = yield* VersionManager
    const xcode = yield* XcodeBuild
    const codesign = yield* CodeSign
    const path = yield* Path.Path
    const fs = yield* FileSystem.FileSystem

    yield* Effect.log("🚀 Starting Hex release process...")

    // Setup directories
    const buildDir = path.join(process.cwd(), "build")
    const updatesDir = path.join(process.cwd(), "updates")
    yield* fs.makeDirectory(buildDir, { recursive: true })
    yield* fs.makeDirectory(updatesDir, { recursive: true })

    // Version management
    const currentVersion = yield* vm.getVersion
    yield* Effect.log(`Current version: ${currentVersion}`)

    const newVersion = yield* vm.bumpVersion(bump)
    yield* vm.updateVersion(newVersion)
    yield* vm.updateXcodeVersion(newVersion)
    yield* vm.incrementBuildNumber()

    yield* Effect.log(`Bumped to version: ${newVersion}`)

    // Build and export
    const archivePath = path.join(buildDir, "Hex.xcarchive")
    const result = yield* xcode.buildAndExport(archivePath, buildDir)

    // Notarize app
    yield* codesign.notarizeApp(result.appPath)

    // Create and notarize DMG
    const dmgFilename = `Hex-${newVersion}.dmg`
    const dmgPath = path.join(buildDir, dmgFilename)
    yield* codesign.createDMG(result.appPath, dmgPath)
    yield* codesign.notarizeDMG(dmgPath)

    // Move to updates dir
    const finalDmgPath = path.join(updatesDir, dmgFilename)
    yield* fs.rename(dmgPath, finalDmgPath)

    // Generate appcast
    yield* Effect.log("Generating appcast...")
    yield* Effect.promise(() =>
      Bun.spawn(["./bin/generate_appcast", "--maximum-deltas", "0", updatesDir], {
        stdout: "inherit",
        stderr: "inherit",
      }).exited
    )

    // Upload to S3
    yield* s3.upload(finalDmgPath, dmgFilename)
    yield* s3.upload(finalDmgPath, "hex-latest.dmg")

    const appcastPath = path.join(updatesDir, "appcast.xml")
    yield* s3.upload(appcastPath, "appcast.xml", "application/xml")

    yield* Effect.log(`\n✅ Release successful! Version ${newVersion} deployed`)
    yield* Effect.log(`   URL: ${s3.getUrl(dmgFilename)}`)
  })
).pipe(Command.withDescription("Build, sign, notarize, and release to S3"))
