/**
 * Live implementation of S3 service
 */
import { Effect, Layer, Config } from "effect"
import { FileSystem } from "@effect/platform"
import { S3Client, PutObjectCommand, ListObjectsV2Command, GetObjectCommand } from "@aws-sdk/client-s3"
import { S3, type S3Version } from "../services/S3.js"
import * as AppConfig from "../config.js"

export const S3Live = Layer.effect(
  S3,
  Effect.gen(function* () {
    const bucket = yield* AppConfig.bucket
    const region = yield* AppConfig.region
    const fs = yield* FileSystem.FileSystem

    const client = new S3Client({ region })

    return S3.of({
      upload: (filePath, key, contentType) =>
        Effect.gen(function* () {
          const fileContent = yield* fs.readFile(filePath)

          const type = contentType ?? (
            key.endsWith(".xml") ? "application/xml" :
            key.endsWith(".zip") ? "application/zip" :
            key.endsWith(".dmg") ? "application/x-apple-diskimage" :
            "application/octet-stream"
          )

          yield* Effect.promise(() =>
            client.send(
              new PutObjectCommand({
                Bucket: bucket,
                Key: key,
                Body: fileContent,
                ContentType: type,
              })
            )
          )

          yield* Effect.log(`✓ Uploaded ${filePath} to s3://${bucket}/${key}`)
        }),

      listVersions: (prefix = "Hex-") =>
        Effect.gen(function* () {
          yield* Effect.log(`Listing S3 objects from s3://${bucket}/${prefix}`)

          const response = yield* Effect.tryPromise({
            try: () =>
              client.send(
                new ListObjectsV2Command({
                  Bucket: bucket,
                  Prefix: prefix,
                })
              ),
            catch: (error) => new Error(`S3 ListObjects failed: ${error}`)
          })

          yield* Effect.log(`Found ${response.Contents?.length ?? 0} total objects`)

          const versions: S3Version[] = (response.Contents ?? [])
            .filter(obj => obj.Key?.endsWith(".dmg"))
            .map(obj => ({
              key: obj.Key!,
              lastModified: obj.LastModified!,
              size: obj.Size ?? 0,
            }))
            .sort((a, b) => b.lastModified.getTime() - a.lastModified.getTime())

          yield* Effect.log(`Filtered to ${versions.length} DMG files`)
          return versions
        }),

      download: (key, destination) =>
        Effect.gen(function* () {
          const response = yield* Effect.promise(() =>
            client.send(
              new GetObjectCommand({
                Bucket: bucket,
                Key: key,
              })
            )
          )

          if (!response.Body) {
            return yield* Effect.fail(new Error(`No body in S3 response for ${key}`))
          }

          const bytes = yield* Effect.promise(() =>
            response.Body!.transformToByteArray()
          )

          yield* fs.writeFile(destination, bytes)
          yield* Effect.log(`✓ Downloaded s3://${bucket}/${key} to ${destination}`)
        }),

      getUrl: (key) => `https://${bucket}.s3.${region}.amazonaws.com/${key}`,
    })
  })
)
