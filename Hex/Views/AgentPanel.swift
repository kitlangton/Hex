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

  /// The card follows the cursor, but only within the central `centerGutterFraction` of the
  /// screen — so however far out (or at the edge) the mouse is, the card always spawns in a
  /// narrow central band rather than hugging a corner.
  private let centerGutterFraction: CGFloat = 0.40

  /// Place the panel near the mouse (which is over the terminal), confined to a central
  /// gutter and clamped on-screen.
  func positionNearMouse() {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    guard let screen else { return }
    let vf = screen.visibleFrame

    // Anchor the card's center under the cursor horizontally, and a little below it
    // vertically (so it sits beneath where you're pointing, not on top of it).
    var center = NSPoint(x: mouse.x, y: mouse.y - frame.height / 2 - 24)

    // Gutter: keep that center inside the central 40% of the screen on both axes.
    let halfBandW = vf.width * centerGutterFraction / 2
    let halfBandH = vf.height * centerGutterFraction / 2
    center.x = min(max(center.x, vf.midX - halfBandW), vf.midX + halfBandW)
    center.y = min(max(center.y, vf.midY - halfBandH), vf.midY + halfBandH)

    var origin = NSPoint(x: center.x - frame.width / 2, y: center.y - frame.height / 2)
    // Safety net: never let any part of the card fall off-screen (tiny displays / tall card).
    origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - frame.width - 8)
    origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - frame.height - 8)
    setFrameOrigin(origin)
  }
}
