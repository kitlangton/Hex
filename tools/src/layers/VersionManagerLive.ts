/**
 * Live implementation of VersionManager service
 */
import { Effect, Layer, pipe } from "effect"
import { Command } from "@effect/platform"
import { VersionManager, type BumpType } from "../services/VersionManager.js"
import * as AppConfig from "../config.js"

export const VersionManagerLive = Layer.effect(
  VersionManager,
  Effect.gen(function* () {
    const plistPath = yield* AppConfig.plistPath

    const runPlistBuddy = (operation: string) =>
      pipe(
        Command.make("/usr/libexec/PlistBuddy", "-c", operation, plistPath),
        Command.string,
        Effect.map(s => s.trim())
      )

    const runSed = (pattern: string, file: string) =>
      pipe(
        Command.make("sed", "-i", "", pattern, file),
        Command.exitCode,
        Effect.flatMap(code =>
          code === 0
            ? Effect.void
            : Effect.fail(new Error(`sed failed with code ${code}`))
        )
      )

    const getVersion = runPlistBuddy("Print CFBundleShortVersionString")

    const getBuildNumber = pipe(
      runPlistBuddy("Print CFBundleVersion"),
      Effect.catchAll(() => Effect.succeed("0"))
    )

    const bumpVersion = (type: BumpType) =>
      Effect.gen(function* () {
        const current = yield* getVersion
        const [major, minor, patch] = current.split(".").map(Number)

        const newVersion =
          type === "major" ? `${major + 1}.0.0` :
          type === "minor" ? `${major}.${minor + 1}.0` :
          `${major}.${minor}.${patch + 1}`

        return newVersion
      })

    const updateVersion = (newVersion: string) =>
      pipe(
        runPlistBuddy(`Set CFBundleShortVersionString ${newVersion}`),
        Effect.asVoid,
        Effect.tap(() => Effect.log(`Updated version to ${newVersion}`))
      )

    const updateXcodeVersion = (newVersion: string) =>
      pipe(
        runSed(
          `s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = ${newVersion};/g`,
          "Hex.xcodeproj/project.pbxproj"
        ),
        Effect.tap(() => Effect.log(`Updated Xcode marketing version to ${newVersion}`))
      )

    const incrementBuildNumber = Effect.gen(function* () {
      const current = yield* getBuildNumber
      const newBuild = String(Number(current) + 1)

      yield* runPlistBuddy(`Set CFBundleVersion ${newBuild}`)
      yield* runSed(
        `s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = ${newBuild};/g`,
        "Hex.xcodeproj/project.pbxproj"
      )
      yield* Effect.log(`Incremented build number to ${newBuild}`)

      return newBuild
    })

    return VersionManager.of({
      getVersion,
      getBuildNumber,
      getVersionInfo: Effect.all([getVersion, getBuildNumber]).pipe(
        Effect.map(([version, buildNumber]) => ({ version, buildNumber }))
      ),
      bumpVersion,
      updateVersion,
      updateXcodeVersion,
      incrementBuildNumber,
    })
  })
)
