/**
 * Live implementation of XcodeBuild service
 */
import { Effect, Layer, pipe } from "effect"
import { Command, FileSystem, Path } from "@effect/platform"
import { XcodeBuild } from "../services/XcodeBuild.js"
import * as AppConfig from "../config.js"

export const XcodeBuildLive = Layer.effect(
  XcodeBuild,
  Effect.gen(function* () {
    const scheme = yield* AppConfig.scheme
    const exportOptionsPath = yield* AppConfig.exportOptionsPath
    const fs = yield* FileSystem.FileSystem
    const path = yield* Path.Path

    const buildDir = path.join(process.cwd(), "build")
    const derivedDataPath = path.join(buildDir, "DerivedData")

    const runXcodebuild = (...args: string[]) =>
      pipe(
        Command.make("xcodebuild", ...args),
        Command.exitCode,
        Effect.flatMap(code =>
          code === 0
            ? Effect.void
            : Effect.fail(new Error(`xcodebuild failed with code ${code}`))
        )
      )

    const clean = Effect.gen(function* () {
      // Remove DerivedData to prevent stale entitlements
      yield* Effect.promise(() =>
        Bun.write(derivedDataPath, "").then(() => {})
      ).pipe(Effect.ignore)

      yield* runXcodebuild(
        "clean",
        "-scheme",
        scheme,
        "-configuration",
        "Release",
        "-derivedDataPath",
        derivedDataPath
      )

      yield* Effect.log("✓ Cleaned build and DerivedData")
    })

    const archive = (archivePath: string) =>
      pipe(
        runXcodebuild(
          "archive",
          "-scheme",
          scheme,
          "-archivePath",
          archivePath,
          "-configuration",
          "Release",
          "-derivedDataPath",
          derivedDataPath,
          "CODE_SIGN_STYLE=Automatic"
        ),
        Effect.tap(() => Effect.log(`✓ Archive created at ${archivePath}`))
      )

    const exportApp = (archivePath: string, exportPath: string) =>
      Effect.gen(function* () {
        yield* runXcodebuild(
          "-exportArchive",
          "-archivePath",
          archivePath,
          "-exportOptionsPlist",
          exportOptionsPath,
          "-exportPath",
          exportPath,
          "-allowProvisioningUpdates"
        )

        const appPath = path.join(exportPath, "Hex.app")
        yield* Effect.log(`✓ App exported to ${appPath}`)

        return appPath
      })

    const buildAndExport = (archivePath: string, exportPath: string) =>
      Effect.gen(function* () {
        // Ensure build dir exists
        yield* fs.makeDirectory(buildDir, { recursive: true })

        yield* clean
        yield* archive(archivePath)
        const appPath = yield* exportApp(archivePath, exportPath)

        return {
          archivePath,
          exportPath,
          appPath,
        }
      })

    return XcodeBuild.of({
      clean,
      archive,
      export: exportApp,
      buildAndExport,
    })
  })
)
