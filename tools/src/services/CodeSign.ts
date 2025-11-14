/**
 * Code signing and notarization service
 */
import { Context, Effect } from "effect"

export interface CodeSign {
  readonly verify: (path: string) => Effect.Effect<void, Error>

  readonly signDMG: (dmgPath: string) => Effect.Effect<void, Error>

  readonly createDMG: (
    appBundle: string,
    dmgPath: string
  ) => Effect.Effect<void, Error>

  readonly notarizeApp: (appPath: string) => Effect.Effect<void, Error>

  readonly notarizeDMG: (dmgPath: string) => Effect.Effect<void, Error>
}

export class CodeSign extends Context.Tag("hex/CodeSign")<CodeSign, CodeSign>() {}
