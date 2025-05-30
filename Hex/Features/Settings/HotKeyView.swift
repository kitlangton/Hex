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
      .frame(width: 48, height: 48)
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

#Preview {
  HotKeyView(
    modifiers: .init(modifiers: [.command, .shift]),
    key: .a,
    isActive: true
  )
}
