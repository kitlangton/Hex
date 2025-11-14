/**
 * Live implementation of CodeSign service
 */
import { Effect, Layer, pipe } from "effect"
import { Command, Path } from "@effect/platform"
import { CodeSign } from "../services/CodeSign.js"

const DEVELOPER_ID = "Developer ID Application: Christopher Langton (QC99C9JE59)"

export const CodeSignLive = Layer.effect(
  CodeSign,
  Effect.gen(function* () {
    const path = yield* Path.Path

    const runCommand = (...args: string[]) =>
      pipe(
        Command.make(...args),
        Command.exitCode,
        Effect.flatMap(code =>
          code === 0
            ? Effect.void
            : Effect.fail(new Error(`${args[0]} failed with code ${code}`))
        )
      )

    const verify = (pathToVerify: string) =>
      pipe(
        runCommand("codesign", "--verify", "--verbose=2", pathToVerify),
        Effect.zipRight(
          runCommand("codesign", "--display", "--verbose=2", pathToVerify)
        ),
        Effect.tap(() => Effect.log(`✓ Signature verified for ${pathToVerify}`))
      )

    const signDMG = (dmgPath: string) =>
      pipe(
        runCommand(
          "codesign",
          "--sign",
          DEVELOPER_ID,
          "--timestamp",
          "--options",
          "runtime",
          "--force",
          dmgPath
        ),
        Effect.tap(() => Effect.log(`✓ Signed DMG at ${dmgPath}`))
      )

    const createDMG = (appBundle: string, dmgPath: string) =>
      Effect.gen(function* () {
        yield* verify(appBundle)

        const tempDir = path.join(path.dirname(dmgPath), "temp_dmg")
        const appName = path.basename(appBundle)
        const tempApp = path.join(tempDir, appName)

        // Create temp dir and copy app
        yield* runCommand("mkdir", "-p", tempDir)
        yield* runCommand("cp", "-R", appBundle, tempApp)
        yield* verify(tempApp)

        // Create Applications symlink
        yield* runCommand("ln", "-s", "/Applications", path.join(tempDir, "Applications"))

        // Create DMG
        const tempDmg = `${dmgPath}.temp.dmg`
        yield* runCommand(
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
        yield* runCommand("hdiutil", "convert", tempDmg, "-format", "UDZO", "-o", dmgPath)

        // Sign DMG
        yield* signDMG(dmgPath)
        yield* verify(dmgPath)

        // Clean up
        yield* runCommand("rm", "-rf", tempDir, tempDmg)

        yield* Effect.log(`✓ Created and signed DMG at ${dmgPath}`)
      })

    const notarize = (itemPath: string, isApp: boolean) =>
      Effect.gen(function* () {
        if (isApp) {
          // Apps need to be zipped for notarization
          const notarizeZip = `${itemPath}_notarize.zip`

          yield* runCommand("ditto", "-c", "-k", "--keepParent", itemPath, notarizeZip)
          yield* Effect.log("Submitting for notarization...")
          yield* runCommand(
            "xcrun",
            "notarytool",
            "submit",
            notarizeZip,
            "--keychain-profile",
            "AC_PASSWORD",
            "--wait"
          )

          // Clean up zip
          yield* Effect.promise(() => Bun.write(notarizeZip, "").then(() => {})).pipe(
            Effect.ignore
          )
        } else {
          // DMGs can be submitted directly
          yield* Effect.log("Submitting DMG for notarization...")
          yield* runCommand(
            "xcrun",
            "notarytool",
            "submit",
            itemPath,
            "--keychain-profile",
            "AC_PASSWORD",
            "--wait"
          )
        }

        // Staple
        yield* Effect.log("Stapling notarization ticket...")
        yield* runCommand("xcrun", "stapler", "staple", itemPath)

        yield* Effect.log(`✓ Notarized and stapled ${itemPath}`)
      })

    return CodeSign.of({
      verify,
      signDMG,
      createDMG,
      notarizeApp: (appPath) => notarize(appPath, true),
      notarizeDMG: (dmgPath) => notarize(dmgPath, false),
    })
  })
)
