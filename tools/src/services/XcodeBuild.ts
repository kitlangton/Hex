/**
 * Xcode build service - xcodebuild operations
 */
import { Context, Effect } from "effect"

export interface BuildResult {
  readonly archivePath: string
  readonly exportPath: string
  readonly appPath: string
}

export interface XcodeBuild {
  readonly clean: Effect.Effect<void, Error>

  readonly archive: (archivePath: string) => Effect.Effect<void, Error>

  readonly export: (
    archivePath: string,
    exportPath: string
  ) => Effect.Effect<string, Error> // Returns app path

  readonly buildAndExport: (
    archivePath: string,
    exportPath: string
  ) => Effect.Effect<BuildResult, Error>
}

export class XcodeBuild extends Context.Tag("hex/XcodeBuild")<XcodeBuild, XcodeBuild>() {}
