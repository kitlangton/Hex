/**
 * Layer compositions and exports
 */
import { Layer } from "effect"
import { NodeContext } from "@effect/platform-node"
import { S3Live } from "./S3Live.js"
import { VersionManagerLive } from "./VersionManagerLive.js"
import { XcodeBuildLive } from "./XcodeBuildLive.js"
import { CodeSignLive } from "./CodeSignLive.js"

/**
 * All services layer - compose all service layers
 */
export const AllServicesLive = Layer.mergeAll(
  S3Live,
  VersionManagerLive,
  XcodeBuildLive,
  CodeSignLive
)

/**
 * Main application layer - All services + NodeContext
 * NodeContext provides CommandExecutor, FileSystem, Path, etc.
 */
export const MainLive = Layer.mergeAll(AllServicesLive, NodeContext.layer)

// Re-export individual layers
export { S3Live, VersionManagerLive, XcodeBuildLive, CodeSignLive }
