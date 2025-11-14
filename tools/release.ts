#!/usr/bin/env bun
/**
 * Hex Release Tool - Effect/TypeScript version
 *
 * Automates building, signing, notarizing, and deploying Hex updates to S3
 */

import { Command } from "@effect/platform"
import { NodeContext, NodeRuntime } from "@effect/platform-node"
import { Console, Effect, Config, Secret, pipe } from "effect"
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3"
import { readFile } from "fs/promises"
import { join } from "path"

// ============================================================================
// Configuration
// ============================================================================

const ReleaseConfig = Config.all({
  // Build settings
  bucket: Config.string("BUCKET").pipe(Config.withDefault("hex-updates")),
  region: Config.string("AWS_REGION").pipe(Config.withDefault("us-east-1")),
  scheme: Config.string("SCHEME").pipe(Config.withDefault("Hex")),
  plistPath: Config.string("PLIST_PATH").pipe(Config.withDefault("Hex/Info.plist")),
  exportOptions: Config.string("EXPORT_OPTIONS").pipe(Config.withDefault("ExportOptions.plist")),
  version: Config.string("VERSION").pipe(Config.option),

  // AWS credentials (optional - uses ~/.aws/credentials if not provided)
  awsAccessKeyId: Config.string("AWS_ACCESS_KEY_ID").pipe(Config.option),
  awsSecretAccessKey: Config.secret("AWS_SECRET_ACCESS_KEY").pipe(Config.option),

  // Apple credentials (optional - uses keychain if not provided)
  appleId: Config.string("APPLE_ID").pipe(Config.option),
  applePassword: Config.secret("APPLE_ID_PASSWORD").pipe(Config.option),
  teamId: Config.string("TEAM_ID").pipe(Config.option),
})

type ReleaseConfig = Config.Config.Success<typeof ReleaseConfig>

// ============================================================================
// Command Execution Helpers
// ============================================================================

/**
 * Get notarization args based on config (uses keychain if no Apple creds provided)
 */
const getNotarizeArgs = (config: ReleaseConfig) => {
  if (config.appleId && config.applePassword && config.teamId) {
    // Use provided credentials (CI)
    return [
      "--apple-id",
      config.appleId,
      "--password",
      Secret.value(config.applePassword),
      "--team-id",
      config.teamId,
    ]
  }
  // Use keychain profile (local)
  return ["--keychain-profile", "AC_PASSWORD"]
}

/**
 * Run a command and return stdout as string
 */
const runCommand = (name: string, ...args: string[]) =>
  pipe(
    Command.make(name, ...args),
    Command.string,
    Effect.tap((output) => Console.log(`✓ ${name} ${args.join(" ")}`)),
    Effect.tapError((error) =>
      Console.error(`✗ ${name} ${args.join(" ")} failed:`, error)
    )
  )

/**
 * Run a command and only check exit code
 */
const runCommandCheck = (name: string, ...args: string[]) =>
  pipe(
    Command.make(name, ...args),
    Command.exitCode,
    Effect.tap(() => Console.log(`✓ ${name} ${args.join(" ")}`)),
    Effect.tapError((error) =>
      Console.error(`✗ ${name} ${args.join(" ")} failed:`, error)
    ),
    Effect.flatMap((code) =>
      code === 0
        ? Effect.succeed(void 0)
        : Effect.fail(`Command exited with code ${code}`)
    )
  )

// ============================================================================
// Version Management
// ============================================================================

/**
 * Get version from Info.plist using PlistBuddy
 */
const getVersion = (plistPath: string) =>
  pipe(
    runCommand(
      "/usr/libexec/PlistBuddy",
      "-c",
      "Print CFBundleShortVersionString",
      plistPath
    ),
    Effect.map((output) => output.trim())
  )

/**
 * Get build number from Info.plist
 */
const getBuildNumber = (plistPath: string) =>
  pipe(
    runCommand(
      "/usr/libexec/PlistBuddy",
      "-c",
      "Print CFBundleVersion",
      plistPath
    ),
    Effect.map((output) => output.trim()),
    Effect.catchAll(() => Effect.succeed("0"))
  )

/**
 * Bump semantic version
 */
const bumpVersion = (version: string, bumpType: "major" | "minor" | "patch" = "patch") => {
  const [major, minor, patch] = version.split(".").map(Number)

  switch (bumpType) {
    case "major":
      return `${major + 1}.0.0`
    case "minor":
      return `${major}.${minor + 1}.0`
    case "patch":
      return `${major}.${minor}.${patch + 1}`
  }
}

/**
 * Update version in Info.plist
 */
const updateVersion = (plistPath: string, newVersion: string) =>
  pipe(
    runCommandCheck(
      "/usr/libexec/PlistBuddy",
      "-c",
      `Set CFBundleShortVersionString ${newVersion}`,
      plistPath
    ),
    Effect.tap(() => Console.log(`Updated version to ${newVersion}`))
  )

/**
 * Update MARKETING_VERSION in Xcode project
 */
const updateXcodeVersion = (newVersion: string) =>
  pipe(
    runCommandCheck(
      "sed",
      "-i",
      "",
      `s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = ${newVersion};/g`,
      "Hex.xcodeproj/project.pbxproj"
    ),
    Effect.tap(() => Console.log(`Updated Xcode marketing version to ${newVersion}`))
  )

/**
 * Increment build number
 */
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
        Effect.tap(() => Console.log(`Incremented build number to ${newBuild}`)),
        Effect.as(newBuild)
      )
    )
  )

// ============================================================================
// Build & Archive
// ============================================================================

/**
 * Build and archive the app
 */
const cleanBuildFolder = (scheme: string, derivedDataPath: string) =>
  pipe(
    runCommandCheck(
      "xcodebuild",
      "clean",
      "-scheme",
      scheme,
      "-configuration",
      "Release",
      "-derivedDataPath",
      derivedDataPath
    ),
    Effect.tap(() => Console.log(`✓ Cleaned build (DerivedData: ${derivedDataPath})`))
  )

const buildArchive = (scheme: string, archivePath: string, derivedDataPath: string) =>
  pipe(
    runCommandCheck(
      "xcodebuild",
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
    Effect.tap(() => Console.log(`✓ Archive created at ${archivePath}`))
  )

/**
 * Export the app from archive
 */
const exportApp = (archivePath: string, exportOptions: string, exportPath: string) =>
  pipe(
    runCommandCheck(
      "xcodebuild",
      "-exportArchive",
      "-archivePath",
      archivePath,
      "-exportOptionsPlist",
      exportOptions,
      "-exportPath",
      exportPath,
      "-allowProvisioningUpdates"
    ),
    Effect.tap(() => Console.log(`✓ App exported to ${exportPath}`))
  )

/**
 * Verify code signature
 */
const verifySignature = (path: string) =>
  pipe(
    runCommandCheck("codesign", "--verify", "--verbose=2", path),
    Effect.zipRight(runCommandCheck("codesign", "--display", "--verbose=2", path)),
    Effect.tap(() => Console.log(`✓ Signature verified for ${path}`))
  )

// ============================================================================
// Notarization
// ============================================================================

/**
 * Notarize app
 */
const notarizeApp = (appPath: string, config: ReleaseConfig) =>
  pipe(
    Effect.gen(function* () {
      const notarizeZip = `${appPath}_notarize.zip`

      // Create zip for notarization
      yield* runCommandCheck("ditto", "-c", "-k", "--keepParent", appPath, notarizeZip)

      // Submit for notarization
      yield* Console.log("Submitting app for notarization...")
      const notarizeArgs = getNotarizeArgs(config)
      yield* runCommandCheck(
        "xcrun",
        "notarytool",
        "submit",
        notarizeZip,
        ...notarizeArgs,
        "--wait"
      )

      // Clean up
      yield* Effect.promise(() => Bun.write(notarizeZip, "").then(() => {}))

      // Staple
      yield* Console.log("Stapling notarization ticket...")
      yield* runCommandCheck("xcrun", "stapler", "staple", appPath)

      yield* Console.log("✓ App successfully notarized and stapled")
    })
  )

/**
 * Create signed DMG
 */
const createSignedDMG = (appBundle: string, dmgPath: string) =>
  pipe(
    Effect.gen(function* () {
      // Verify app signature
      yield* verifySignature(appBundle)

      const tempDir = join(process.cwd(), "build", "temp_dmg")
      const appName = appBundle.split("/").pop()!
      const tempApp = join(tempDir, appName)

      // Create temp dir and copy app
      yield* runCommandCheck("mkdir", "-p", tempDir)
      yield* runCommandCheck("cp", "-R", appBundle, tempApp)
      yield* verifySignature(tempApp)

      // Create Applications symlink
      yield* runCommandCheck("ln", "-s", "/Applications", join(tempDir, "Applications"))

      // Create DMG
      const tempDmg = `${dmgPath}.temp.dmg`
      yield* runCommandCheck(
        "hdiutil",
        "create",
        "-format",
        "UDRW",
        "-fs",
        "APFS",
        "-volname",
        "Hex",
        "-srcfolder",
        tempDir,
        tempDmg
      )

      // Convert to compressed
      yield* runCommandCheck("hdiutil", "convert", tempDmg, "-format", "UDZO", "-o", dmgPath)

      // Sign DMG
      yield* runCommandCheck(
        "codesign",
        "--sign",
        "Developer ID Application: Christopher Langton (QC99C9JE59)",
        "--timestamp",
        "--options",
        "runtime",
        "--force",
        dmgPath
      )

      yield* verifySignature(dmgPath)

      // Clean up
      yield* runCommandCheck("rm", "-rf", tempDir, tempDmg)

      yield* Console.log(`✓ Created and signed DMG at ${dmgPath}`)
    })
  )

/**
 * Notarize DMG
 */
const notarizeDMG = (dmgPath: string, config: ReleaseConfig) =>
  pipe(
    Effect.gen(function* () {
      yield* Console.log("Submitting DMG for notarization...")
      const notarizeArgs = getNotarizeArgs(config)
      yield* runCommandCheck(
        "xcrun",
        "notarytool",
        "submit",
        dmgPath,
        ...notarizeArgs,
        "--wait"
      )

      yield* Console.log("Stapling notarization ticket to DMG...")
      yield* runCommandCheck("xcrun", "stapler", "staple", dmgPath)

      yield* Console.log("✓ DMG successfully notarized and stapled")
    })
  )

// ============================================================================
// S3 Upload
// ============================================================================

/**
 * Upload file to S3
 */
const uploadToS3 = (filePath: string, bucket: string, key: string, config: ReleaseConfig) =>
  pipe(
    Effect.gen(function* () {
      // Use explicit credentials if provided, otherwise AWS SDK uses default credential chain
      const credentials =
        config.awsAccessKeyId && config.awsSecretAccessKey
          ? {
              accessKeyId: config.awsAccessKeyId,
              secretAccessKey: Secret.value(config.awsSecretAccessKey),
            }
          : undefined

      const client = new S3Client({
        region: config.region,
        ...(credentials && { credentials }),
      })
      const fileContent = yield* Effect.promise(() => readFile(filePath))

      const contentType = key.endsWith(".xml")
        ? "application/xml"
        : key.endsWith(".zip")
        ? "application/zip"
        : "application/octet-stream"

      yield* Effect.promise(() =>
        client.send(
          new PutObjectCommand({
            Bucket: bucket,
            Key: key,
            Body: fileContent,
            ContentType: contentType,
          })
        )
      )

      yield* Console.log(`✓ Uploaded ${filePath} to s3://${bucket}/${key}`)
    })
  )

/**
 * Generate appcast using Sparkle
 */
const generateAppcast = (updatesDir: string) =>
  pipe(
    runCommandCheck("./bin/generate_appcast", "--maximum-deltas", "0", updatesDir),
    Effect.tap(() => Console.log("✓ Generated appcast.xml"))
  )

// ============================================================================
// Main Release Flow
// ============================================================================

const main = Effect.gen(function* () {
  const config = yield* ReleaseConfig

  yield* Console.log("🚀 Starting Hex release process...")

  // Setup directories
  const buildDir = join(process.cwd(), "build")
  const updatesDir = join(process.cwd(), "updates")
  const derivedDataPath = join(buildDir, "DerivedData")
  yield* runCommandCheck("mkdir", "-p", buildDir, updatesDir)
  yield* runCommandCheck("rm", "-rf", derivedDataPath)

  // Version management - use VERSION env if provided (from git tag), else bump
  const newVersion = config.version
    ? config.version.replace(/^v/, "") // Strip 'v' prefix if present
    : (() => {
        const current = yield* getVersion(config.plistPath)
        return bumpVersion(current, "patch")
      })()

  yield* Console.log(`Release version: ${newVersion}`)
  yield* updateVersion(config.plistPath, newVersion)
  yield* updateXcodeVersion(newVersion)
  yield* incrementBuildNumber(config.plistPath)

  // Build and archive
  const archivePath = join(buildDir, "Hex.xcarchive")
  yield* cleanBuildFolder(config.scheme, derivedDataPath)
  yield* buildArchive(config.scheme, archivePath, derivedDataPath)

  // Export
  yield* exportApp(archivePath, config.exportOptions, buildDir)

  // Notarize app
  const appBundle = join(buildDir, "Hex.app")
  yield* notarizeApp(appBundle, config)

  // Create ZIP for Homebrew
  const zipFilename = `Hex-${newVersion}.zip`
  const zipPath = join(updatesDir, zipFilename)
  yield* runCommandCheck("ditto", "-c", "-k", "--keepParent", appBundle, zipPath)
  yield* Console.log(`✓ Created ZIP at ${zipPath}`)

  // Create and notarize DMG
  const dmgFilename = `Hex-${newVersion}.dmg`
  const dmgPath = join(buildDir, dmgFilename)
  yield* createSignedDMG(appBundle, dmgPath)
  yield* notarizeDMG(dmgPath, config)

  // Move to updates dir
  const finalDmgPath = join(updatesDir, dmgFilename)
  yield* runCommandCheck("mv", dmgPath, finalDmgPath)

  // Generate appcast
  yield* generateAppcast(updatesDir)

  // Upload to S3
  yield* uploadToS3(finalDmgPath, config.bucket, dmgFilename, config)
  yield* uploadToS3(finalDmgPath, config.bucket, "hex-latest.dmg", config)
  yield* uploadToS3(zipPath, config.bucket, zipFilename, config)

  const appcastPath = join(updatesDir, "appcast.xml")
  yield* uploadToS3(appcastPath, config.bucket, "appcast.xml", config)

  yield* Console.log(`✅ Deployment successful! Version ${newVersion} deployed to bucket ${config.bucket}`)
})

// Run the program
NodeRuntime.runMain(main.pipe(Effect.provide(NodeContext.layer)))
