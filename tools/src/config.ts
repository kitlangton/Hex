/**
 * Application configuration using Effect Config
 */
import { Config } from "effect"

// Define all config entries
export const bucket = Config.string("BUCKET").pipe(
  Config.withDefault("hex-updates")
)

export const region = Config.string("AWS_REGION").pipe(
  Config.withDefault("us-east-1")
)

export const scheme = Config.string("XCODE_SCHEME").pipe(
  Config.withDefault("Hex")
)

export const plistPath = Config.string("PLIST_PATH").pipe(
  Config.withDefault("Hex/Info.plist")
)

export const exportOptionsPath = Config.string("EXPORT_OPTIONS_PATH").pipe(
  Config.withDefault("ExportOptions.plist")
)

// Composite config
export const appConfig = Config.all({
  bucket,
  region,
  scheme,
  plistPath,
  exportOptionsPath,
})
