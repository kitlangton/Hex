//
//  CancelConfirmationView.swift
//  Hex
//

import Inject
import SwiftUI

struct CancelConfirmationView: View {
  @ObserveInjection var inject

  var onDestroy: () -> Void
  var onContinue: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      // Continue Recording button (green) with C keycap
      Button(action: onContinue) {
        HStack(spacing: 5) {
          Text("Continue Recording")
            .font(.system(size: 11, weight: .medium, design: .rounded))

          Keycap("c")
        }
        .foregroundStyle(.green)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(Color.green.opacity(0.15))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color.green.opacity(0.3), lineWidth: 1)
        )
      }
      .buttonStyle(.plain)

      // Destroy button (red) with ESC keycap
      Button(action: onDestroy) {
        HStack(spacing: 5) {
          Text("Destroy")
            .font(.system(size: 11, weight: .semibold, design: .rounded))

          Keycap("esc")
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(Color.red.opacity(0.15))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color.red.opacity(0.3), lineWidth: 1)
        )
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(.ultraThinMaterial)
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color.white.opacity(0.08), lineWidth: 1)
    )
    .enableInjection()
  }
}

/// A cute little keyboard keycap badge
private struct Keycap: View {
  let label: String

  init(_ label: String) {
    self.label = label
  }

  var body: some View {
    Text(label)
      .font(.system(size: 9, weight: .bold, design: .rounded))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(
        RoundedRectangle(cornerRadius: 3)
          .fill(Color.white.opacity(0.08))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 3)
          .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
      )
  }
}

#Preview("Cancel Confirmation") {
  ZStack {
    Color.black
    CancelConfirmationView(
      onDestroy: {},
      onContinue: {}
    )
  }
  .frame(width: 300, height: 100)
}
