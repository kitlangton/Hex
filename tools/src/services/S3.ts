/**
 * S3 service - AWS S3 operations
 */
import { Context, Effect, Stream } from "effect"

export interface S3Version {
  readonly key: string
  readonly lastModified: Date
  readonly size: number
}

export interface S3 {
  readonly upload: (
    filePath: string,
    key: string,
    contentType?: string
  ) => Effect.Effect<void, Error>

  readonly listVersions: (prefix?: string) => Effect.Effect<ReadonlyArray<S3Version>, Error>

  readonly download: (key: string, destination: string) => Effect.Effect<void, Error>

  readonly getUrl: (key: string) => string
}

export class S3 extends Context.Tag("hex/S3")<S3, S3>() {}
