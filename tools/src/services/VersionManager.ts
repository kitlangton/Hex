/**
 * Version management service - reading/writing versions from plists and Xcode project
 */
import { Context, Effect } from "effect"

export type BumpType = "major" | "minor" | "patch"

export interface VersionInfo {
  readonly version: string
  readonly buildNumber: string
}

export interface VersionManager {
  readonly getVersion: Effect.Effect<string, Error>

  readonly getBuildNumber: Effect.Effect<string, Error>

  readonly getVersionInfo: Effect.Effect<VersionInfo, Error>

  readonly bumpVersion: (type: BumpType) => Effect.Effect<string, Error>

  readonly incrementBuildNumber: Effect.Effect<string, Error>

  readonly updateVersion: (newVersion: string) => Effect.Effect<void, Error>

  readonly updateXcodeVersion: (newVersion: string) => Effect.Effect<void, Error>
}

export class VersionManager extends Context.Tag("hex/VersionManager")<
  VersionManager,
  VersionManager
>() {}
