//
//  HotKeyView.swift
//  Hex
//
//  Created by Kit Langton on 1/30/25.
//

import Inject
import Sauce
import SwiftUI

// This view shows the actual "keys" in a more modern, subtle style.
struct HotKeyView: View {
  @ObserveInjection var inject
  var modifiers: Modifiers
  var key: Key?
  var isActive: Bool

  var body: some View {
    HStack(spacing: 6) {
      if modifiers.isHyperkey {
        // Show Black Four Pointed Star for hyperkey
        KeyView(text: "✦")
          .transition(.blurReplace)
      } else {
        ForEach(modifiers.sorted) { modifier in
          KeyView(text: modifier.stringValue)
            .transition(.blurReplace)
        }
      }
      
      if let key {
        KeyView(text: key.toString)
      }

      if modifiers.isEmpty && key == nil {
        Text("")
          .font(.system(size: 12, weight: .regular, design: .monospaced))
          .frame(width: 48, height: 48)
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity)
    .background {
      if isActive && key == nil && modifiers.isEmpty {
        Text("Enter a key combination")
          .foregroundColor(.secondary)
          .transition(.blurReplace)
      }
    }
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(Color.blue.opacity(isActive ? 0.1 : 0))
        .stroke(Color.blue.opacity(isActive ? 0.2 : 0), lineWidth: 1)
    )

    .animation(.bouncy(duration: 0.3), value: key)
    .animation(.bouncy(duration: 0.3), value: modifiers)
    .animation(.bouncy(duration: 0.3), value: isActive)
    .enableInjection()
  }
}

struct KeyView: View {
  @ObserveInjection var inject
  var text: String

  var body: some View {
    Text(text)
      .font(.title.weight(.bold))
      .foregroundColor(.white)
      .frame(minWidth: 48, minHeight: 48, maxHeight: 48)
      .padding(.horizontal, text.count > 2 ? 8 : 0)  // Add padding for L/R prefix
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(
            .black.mix(with: .white, by: 0.2)
              .shadow(.inner(color: .white.opacity(0.3), radius: 1, y: 1))
              .shadow(.inner(color: .white.opacity(0.1), radius: 5, y: 8))
              .shadow(.inner(color: .black.opacity(0.3), radius: 1, y: -3))
          )
      )
      .shadow(radius: 4, y: 2)
      .enableInjection()
  }
}

// MARK: - Modifier Side Controls

struct ModifierSideControls: View {
  @ObserveInjection var inject
  let modifiers: Modifiers
  let onUpdateSide: (Modifier.ModifierType, ModifierSide) -> Void

  var body: some View {
    VStack(spacing: 8) {
      ForEach(sortedModifiersWithSides, id: \.type) { modifierInfo in
        HStack(spacing: 12) {
          // Modifier label
          Text(modifierInfo.displayName)
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(width: 60, alignment: .trailing)

          // Side picker
          Picker("", selection: Binding(
            get: { modifierInfo.currentSide },
            set: { newSide in
              onUpdateSide(modifierInfo.type, newSide)
            }
          )) {
            Text("Either").tag(ModifierSide.either)
            Text("Left").tag(ModifierSide.left)
            Text("Right").tag(ModifierSide.right)
          }
          .pickerStyle(.segmented)
          .frame(width: 200)
        }
      }
    }
    .padding(.vertical, 8)
    .enableInjection()
  }

  private struct ModifierInfo {
    let type: Modifier.ModifierType
    let currentSide: ModifierSide
    let displayName: String
  }

  private var sortedModifiersWithSides: [ModifierInfo] {
    let modifiersWithSides: [Modifier.ModifierType] = [.control, .option, .shift, .command]

    return modifiersWithSides.compactMap { type in
      // Find if this modifier type exists in the current modifiers
      guard let modifier = modifiers.modifiers.first(where: { $0.baseType == type }),
            let side = modifier.side else {
        return nil
      }

      let displayName: String
      switch type {
      case .command: displayName = "⌘ Command"
      case .option: displayName = "⌥ Option"
      case .shift: displayName = "⇧ Shift"
      case .control: displayName = "⌃ Control"
      case .fn: displayName = "fn"
      }

      return ModifierInfo(type: type, currentSide: side, displayName: displayName)
    }
  }
}

#Preview("HotKey View") {
  HotKeyView(
    modifiers: .init(modifiers: [.command(.left), .shift(.right)]),
    key: .a,
    isActive: true
  )
}

#Preview("Modifier Side Controls") {
  ModifierSideControls(
    modifiers: .init(modifiers: [.command(.left), .option(.either), .shift(.right)]),
    onUpdateSide: { type, side in
      print("Update \(type) to \(side)")
    }
  )
  .padding()
}
