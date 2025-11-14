#!/usr/bin/env bun
/**
 * Version bumping tool
 *
 * Updates Info.plist, project.pbxproj, commits, and tags
 */

import { Command } from "@effect/platform"
import { NodeContext, NodeRuntime } from "@effect/platform-node"
import { Console, Effect, pipe } from "effect"
import { join } from "path"

// ============================================================================
// Command Execution Helpers
// ============================================================================

const runCommand = (name: string, ...args: string[]) =>
  pipe(
    Command.make(name, ...args),
    Command.string,
    Effect.map((output) => output.trim())
  )

const runCommandCheck = (name: string, ...args: string[]) =>
  pipe(
    Command.make(name, ...args),
    Command.exitCode,
    Effect.flatMap((code) =>
      code === 0
        ? Effect.succeed(code)
        : Effect.fail(new Error(`${name} ${args.join(" ")} failed with exit code ${code}`))
    )
  )

// ============================================================================
// Version Management
// ============================================================================

const getVersion = (plistPath: string) =>
  pipe(
    runCommand(
      "/usr/libexec/PlistBuddy",
      "-c",
      "Print CFBundleShortVersionString",
      plistPath
    )
  )

const getBuildNumber = (plistPath: string) =>
  pipe(
    runCommand(
      "/usr/libexec/PlistBuddy",
      "-c",
      "Print CFBundleVersion",
      plistPath
    ),
    Effect.catchAll(() => Effect.succeed("0"))
  )

const updateVersion = (plistPath: string, newVersion: string) =>
  pipe(
    runCommandCheck(
      "/usr/libexec/PlistBuddy",
      "-c",
      `Set CFBundleShortVersionString ${newVersion}`,
      plistPath
    ),
    Effect.tap(() => Console.log(`✓ Updated Info.plist to ${newVersion}`))
  )

const updateXcodeVersion = (newVersion: string) =>
  pipe(
    runCommandCheck(
      "sed",
      "-i",
      "",
      `s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = ${newVersion};/g`,
      "Hex.xcodeproj/project.pbxproj"
    ),
    Effect.tap(() => Console.log(`✓ Updated project.pbxproj to ${newVersion}`))
  )

const incrementBuildNumber = (plistPath: string) =>
  pipe(
    getBuildNumber(plistPath),
    Effect.map((current) => String(Number(current) + 1)),
    Effect.flatMap((newBuild) =>
      pipe(
        runCommandCheck(
          "/usr/libexec/PlistBuddy",
          "-c",
          `Set CFBundleVersion ${newBuild}`,
          plistPath
        ),
        Effect.zipRight(
          runCommandCheck(
            "sed",
            "-i",
            "",
            `s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = ${newBuild};/g`,
            "Hex.xcodeproj/project.pbxproj"
          )
        ),
        Effect.tap(() => Console.log(`✓ Incremented build number to ${newBuild}`)),
        Effect.as(newBuild)
      )
    )
  )

const commitAndTag = (version: string) =>
  pipe(
    Effect.gen(function* () {
      // Add changes
      yield* runCommandCheck("git", "add", "Hex/Info.plist", "Hex.xcodeproj/project.pbxproj")

      // Commit
      yield* runCommandCheck("git", "commit", "-m", `Bump version to ${version}`)
      yield* Console.log(`✓ Committed version bump`)

      // Tag
      const tag = `v${version}`
      yield* runCommandCheck("git", "tag", tag)
      yield* Console.log(`✓ Created tag ${tag}`)

      return tag
    })
  )

// ============================================================================
// Main
// ============================================================================

const main = Effect.gen(function* () {
  const args = process.argv.slice(2)

  if (args.length === 0) {
    yield* Console.error("Usage: bun run version.ts <version>")
    yield* Console.error("Example: bun run version.ts 0.3.0")
    return yield* Effect.fail(new Error("Missing version argument"))
  }

  const newVersion = args[0]

  // Detect project root
  const cwd = process.cwd()
  const projectRoot = cwd.endsWith("tools") ? join(cwd, "..") : cwd
  process.chdir(projectRoot)

  const plistPath = "Hex/Info.plist"

  yield* Console.log(`\n🔖 Bumping version to ${newVersion}\n`)

  // Get current version
  const currentVersion = yield* getVersion(plistPath)
  yield* Console.log(`Current version: ${currentVersion}`)

  // Update version
  yield* updateVersion(plistPath, newVersion)
  yield* updateXcodeVersion(newVersion)
  yield* incrementBuildNumber(plistPath)

  // Commit and tag
  const tag = yield* commitAndTag(newVersion)

  yield* Console.log(`\n✅ Version bumped to ${newVersion}`)
  yield* Console.log(`\nTo trigger release:`)
  yield* Console.log(`  git push --follow-tags`)
})

// Run the program
NodeRuntime.runMain(main.pipe(Effect.provide(NodeContext.layer)))
