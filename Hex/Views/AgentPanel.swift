//
//  AgentPanel.swift
//  Hex
//
//  An interactive, non-activating floating panel used by the Agent Plugins feature.
//
//  Unlike `InvisibleWindow` (which ignores the mouse and never becomes key), this panel
//  hosts an editable text field and buttons. `.nonactivatingPanel` + `becomesKeyOnlyIfNeeded`
//  let the text field receive keystrokes WITHOUT making Hex the active application, so the
//  terminal running `claude` stays frontmost and we can paste back into it.
//

import AppKit
import SwiftUI

final class AgentPanel: NSPanel {
  // Must become key so the SwiftUI TextField can receive typed characters.
  override var canBecomeKey: Bool { true }
  // Never become "main" — we don't want to masquerade as the active app's main window.
  override var canBecomeMain: Bool { false }

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
      styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .closable, .resizable],
      backing: .buffered,
      defer: false
    )

    isFloatingPanel = true
    becomesKeyOnlyIfNeeded = true   // only grabs key focus when a control needs it
    level = .floating               // above normal windows (incl. the terminal)
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    standardWindowButton(.closeButton)?.isHidden = true
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden = true
    isMovableByWindowBackground = true
    backgroundColor = .clear
    isOpaque = false
    // Each SwiftUI card draws its own shadow, so the window itself must not.
    hasShadow = false
    hidesOnDeactivate = false        // we control dismissal explicitly
    isReleasedWhenClosed = false
    animationBehavior = .utilityWindow
    // Note: .canJoinAllSpaces and .moveToActiveSpace are mutually exclusive — combining
    // them trips an NSWindow assertion. Use canJoinAllSpaces so the panel follows the user.
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
  }

  static func fromView<V: View>(_ view: V) -> AgentPanel {
    let panel = AgentPanel()
    // A hosting CONTROLLER (not view) makes the window size itself to the SwiftUI
    // content. `.preferredContentSize` is what keeps the window tracking the content
    // as it changes height — without it the fixed 320pt window clips a growing input.
    let host = NSHostingController(rootView: view)
    host.sizingOptions = [.preferredContentSize]
    panel.contentViewController = host
    return panel
  }

  /// Place the panel near the mouse (which is over the terminal), clamped on-screen.
  func positionNearMouse() {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    guard let screen else { return }
    let vf = screen.visibleFrame
    var origin = NSPoint(x: mouse.x - frame.width / 2, y: mouse.y - frame.height - 24)
    origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - frame.width - 8)
    origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - frame.height - 8)
    setFrameOrigin(origin)
  }
}
