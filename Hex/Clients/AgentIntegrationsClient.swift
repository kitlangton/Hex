//
//  AgentIntegrationsClient.swift
//  Hex
//
//  Registry for "Agent Plugins" integrations (Claude Code, pi, future Codex, …). Each
//  integration is a self-contained provider that generates whatever scripts/files it needs
//  inside Hex's container and surfaces an `AgentIntegration` descriptor for the Settings
//  UI to render. AppFeature and SettingsFeature only know about this registry — they never
//  reference individual plugin clients.
//
//  Adding a new integration is two edits:
//    1. Create a new `*PluginClientLive` that conforms to `AgentIntegrationProvider`.
//    2. Append it to the `providers` array in `AgentIntegrationsClient.liveValue` below.
//
//  Nothing else has to change.
//

import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

/// How to render an integration's icon in the Settings UI. Asset → an image from
/// `Assets.xcassets`; Symbol → an SF Symbol. Letting the descriptor declare this means
/// the view can render any integration without an `if/else` per provider.
enum AgentIntegrationIcon: Equatable, Sendable {
  case asset(String)
  case symbol(String)
}

/// UI-facing description of an installed integration. Pure data, safe to live in
/// reducer state.
struct AgentIntegration: Identifiable, Equatable, Sendable {
  let id: String
  let displayName: String
  let icon: AgentIntegrationIcon
  let installCaption: String
  let uninstallCaption: String
  let installCommand: String
  let uninstallCommand: String
}

/// Contract every plugin client implements. `prepare()` is idempotent (call on launch,
/// on toggle, whenever Settings open); `descriptor` is cheap and side-effect-free.
protocol AgentIntegrationProvider: Sendable {
  func prepare()
  var descriptor: AgentIntegration { get }
}

@DependencyClient
struct AgentIntegrationsClient {
  /// Refresh every registered integration's container scripts (idempotent) and return
  /// their UI descriptors. The set of integrations is defined in exactly one place —
  /// the `providers` array in `liveValue` below.
  var prepareAll: @Sendable () async -> [AgentIntegration] = { [] }
}

extension AgentIntegrationsClient: DependencyKey {
  static var liveValue: Self {
    // THE registry. To add an integration, append a provider here.
    let providers: [any AgentIntegrationProvider] = [
      ClaudePluginClientLive(),
      PiPluginClientLive(),
    ]
    return .init(prepareAll: {
      providers.map { provider in
        provider.prepare()
        return provider.descriptor
      }
    })
  }
}

extension DependencyValues {
  var agentIntegrations: AgentIntegrationsClient {
    get { self[AgentIntegrationsClient.self] }
    set { self[AgentIntegrationsClient.self] = newValue }
  }
}
