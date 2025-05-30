//
//  HexCapsuleView.swift
//  Hex
//
//  Created by Kit Langton on 1/25/25.
//

import Pow
import SwiftUI

struct TranscriptionIndicatorView: View {
  enum Status {
    case hidden
    case optionKeyPressed
    case recording
    case transcribing
    case prewarming
    case enhancing
  }

  var status: Status
  var meter: Meter

  let transcribeBaseColor: Color = .blue
  let enhanceBaseColor: Color = .green

  private var backgroundColor: Color {
    switch status {
    case .hidden: return Color.clear
    case .optionKeyPressed: return Color.black
    case .recording: return .red.mix(with: .black, by: 0.5).mix(with: .red, by: meter.averagePower * 3)
    case .transcribing: return transcribeBaseColor.mix(with: .black, by: 0.5)
    case .prewarming: return transcribeBaseColor.mix(with: .black, by: 0.5)
    case .enhancing: return enhanceBaseColor.mix(with: .black, by: 0.5)
    }
  }

  private var strokeColor: Color {
    switch status {
    case .hidden: return Color.clear
    case .optionKeyPressed: return Color.black
    case .recording: return Color.red.mix(with: .white, by: 0.1).opacity(0.6)
    case .transcribing: return transcribeBaseColor.mix(with: .white, by: 0.1).opacity(0.6)
    case .prewarming: return transcribeBaseColor.mix(with: .white, by: 0.1).opacity(0.6)
    case .enhancing: return enhanceBaseColor.mix(with: .white, by: 0.1).opacity(0.6)
    }
  }

  private var innerShadowColor: Color {
    switch status {
    case .hidden: return Color.clear
    case .optionKeyPressed: return Color.clear
    case .recording: return Color.red
    case .transcribing: return transcribeBaseColor
    case .prewarming: return transcribeBaseColor
    case .enhancing: return enhanceBaseColor
    }
  }

  private let cornerRadius: CGFloat = 8
  private let baseWidth: CGFloat = 16
  private let expandedWidth: CGFloat = 56

  var isHidden: Bool {
    status == .hidden
  }

  @State var transcribeEffect = 0
  @State var enhanceEffect = 0

  // Memoize these calculations to prevent recalculating on every render
  private func recordingOpacity(for power: Double, threshold: Double = 0.1) -> Double {
    guard status == .recording else { return 0 }
    return power < threshold ? power / threshold : 1
  }

  // Cache shadow colors based on status and power
  @ViewBuilder
  private func shadowEffect(averagePower: Double) -> some View {
    switch status {
    case .recording:
      EmptyView()
        .shadow(color: .red.opacity(averagePower), radius: 4)
        .shadow(color: .red.opacity(averagePower * 0.5), radius: 8)
    case .enhancing:
      EmptyView()
        .shadow(color: enhanceBaseColor.opacity(0.7), radius: 4)
        .shadow(color: enhanceBaseColor.opacity(0.4), radius: 8)
    case .transcribing, .prewarming:
      EmptyView()
        .shadow(color: transcribeBaseColor.opacity(0.7), radius: 4)
        .shadow(color: transcribeBaseColor.opacity(0.4), radius: 8)
    default:
      EmptyView()
        .shadow(color: .red.opacity(0), radius: 4)
        .shadow(color: .red.opacity(0), radius: 8)
    }
  }

  var body: some View {
    // Fast track for hidden state to avoid expensive calculations
    if status == .hidden {
      EmptyView()
    } else {
      // Only do these calculations when actually visible
      let averagePower = min(1, meter.averagePower * 3)
      let peakPower = min(1, meter.peakPower * 3)
      
      ZStack {
        // Base capsule with all effects - avoid recreating for hidden state
        CapsuleWithEffects(
          status: status,
          cornerRadius: cornerRadius,
          averagePower: averagePower,
          peakPower: peakPower,
          innerShadowColor: innerShadowColor,
          backgroundColor: backgroundColor,
          strokeColor: strokeColor
        )
        .frame(
          width: status == .recording ? expandedWidth : baseWidth,
          height: baseWidth
        )
        // Combine these into a single animation for better performance
        .scaleEffect(status == .optionKeyPressed ? 0.95 : 1)
        .opacity(status == .hidden ? 0 : 1)
        // Apply expensive effects conditionally
        .modifier(LightweightEffects(status: status, enhanceBaseColor: enhanceBaseColor))
        // Only apply these effects during active animation states
        .apply(needsShine: status == .transcribing || status == .enhancing, 
               transcribeEffect: transcribeEffect, 
               enhanceEffect: enhanceEffect)
        .compositingGroup()
        // Efficient animation task
        .task(id: status) {
          // Only animate if we're in a state that needs animation
          guard status == .transcribing || status == .enhancing else { return }
          
          // Use longer delay to reduce CPU usage with split sleep pattern for better cancellation
          while (status == .transcribing || status == .enhancing), !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { break }
            
            // Update the appropriate counter based on current status
            if status == .transcribing {
              transcribeEffect += 1
            } else if status == .enhancing {
              enhanceEffect += 1
            }
            
            try? await Task.sleep(for: .milliseconds(250))
          }
        }
      
        // Show tooltip only for prewarming, not for enhancing
        if status == .prewarming {
          VStack(spacing: 4) {
            Text("Model prewarming...")
              .font(.system(size: 12, weight: .medium))
              .foregroundColor(.white)
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(
                RoundedRectangle(cornerRadius: 4)
                  .fill(Color.black.opacity(0.8))
              )
          }
          .offset(y: -24)
          .transition(.opacity)
          .zIndex(2)
        }
      }
      .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.7), value: status)
    }
  }
}

// Optimized view hierarchy to improve performance
struct CapsuleWithEffects: View {
  var status: TranscriptionIndicatorView.Status
  var cornerRadius: CGFloat
  var averagePower: Double
  var peakPower: Double
  var innerShadowColor: Color
  var backgroundColor: Color
  var strokeColor: Color
  
  // Cache calculated values to avoid recalculation
  private let recordingOpacity: Double
  private let whiteOverlayOpacity: Double
  private let peakOverlayOpacity: Double
  private let primaryShadowColor: Color
  private let secondaryShadowColor: Color
  
  // This will help us avoid constant rebuilding of the view
  @ViewBuilder private var innerOverlays: some View {
    if status == .recording {
      RoundedRectangle(cornerRadius: cornerRadius)
        .fill(Color.red.opacity(recordingOpacity))
        .blur(radius: 2)
        .blendMode(.screen)
        .padding(6)
      
      RoundedRectangle(cornerRadius: cornerRadius)
        .fill(Color.white.opacity(whiteOverlayOpacity))
        .blur(radius: 1)
        .blendMode(.screen)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(7)
    }
  }
  
  // Constructor to pre-calculate all values
  init(status: TranscriptionIndicatorView.Status, cornerRadius: CGFloat, averagePower: Double, peakPower: Double, 
       innerShadowColor: Color, backgroundColor: Color, strokeColor: Color) {
    self.status = status
    self.cornerRadius = cornerRadius
    self.averagePower = averagePower
    self.peakPower = peakPower
    self.innerShadowColor = innerShadowColor
    self.backgroundColor = backgroundColor
    self.strokeColor = strokeColor
    
    // Precalculate all values once during initialization
    self.recordingOpacity = status == .recording ? (averagePower < 0.1 ? averagePower / 0.1 : 1) : 0
    self.whiteOverlayOpacity = status == .recording ? (averagePower < 0.1 ? averagePower / 0.1 : 0.5) : 0
    self.peakOverlayOpacity = status == .recording ? (peakPower < 0.1 ? (peakPower / 0.1) * 0.5 : 0.5) : 0
    
    // Precalculate shadow colors
    switch status {
    case .recording:
      self.primaryShadowColor = .red.opacity(averagePower)
      self.secondaryShadowColor = .red.opacity(averagePower * 0.5)
    case .enhancing:
      self.primaryShadowColor = Color.green.opacity(0.7)
      self.secondaryShadowColor = Color.green.opacity(0.4)
    case .transcribing, .prewarming:
      self.primaryShadowColor = Color.blue.opacity(0.7)
      self.secondaryShadowColor = Color.blue.opacity(0.4)
    default:
      self.primaryShadowColor = .red.opacity(0)
      self.secondaryShadowColor = .red.opacity(0)
    }
  }
  
  var body: some View {
    ZStack {
      // Base capsule
      Capsule()
        .fill(backgroundColor.shadow(.inner(color: innerShadowColor, radius: 4)))
      
      // Border capsule
      Capsule()
        .stroke(strokeColor, lineWidth: 1)
        .blendMode(.screen)
      
      // Conditionally add overlays for performance
      innerOverlays
      
      // Only use GeometryReader when in recording mode
      if status == .recording {
        GeometryReader { proxy in
          RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.red.opacity(peakOverlayOpacity))
            .frame(width: max(proxy.size.width * (peakPower + 0.6), 0), height: proxy.size.height, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .center)
            .blur(radius: 4)
            .blendMode(.screen)
            .padding(6)
        }
      }
    }
    // Apply common modifiers
    .cornerRadius(cornerRadius)
    .shadow(color: primaryShadowColor, radius: 4)
    .shadow(color: secondaryShadowColor, radius: 8)
    .animation(status == .recording ? .interactiveSpring(response: 0.35) : nil, value: averagePower)
  }
}

// Lightweight modifier for effects
struct LightweightEffects: ViewModifier {
  var status: TranscriptionIndicatorView.Status
  var enhanceBaseColor: Color
  
  func body(content: Content) -> some View {
    content.changeEffect(
      .glow(color: status == .enhancing ? enhanceBaseColor.opacity(0.4) : .red.opacity(0.4), radius: 6),
      value: status
    )
  }
}

// Extension to conditionally apply shine effects
extension View {
  @ViewBuilder
  func apply(needsShine: Bool, transcribeEffect: Int, enhanceEffect: Int) -> some View {
    if needsShine {
      self
        .changeEffect(.shine(angle: .degrees(0), duration: 0.8), value: transcribeEffect)
        .changeEffect(.shine(angle: .degrees(0), duration: 0.8), value: enhanceEffect)
    } else {
      self
    }
  }
}

#Preview("HEX") {
  VStack(spacing: 8) {
    TranscriptionIndicatorView(status: .hidden, meter: .init(averagePower: 0, peakPower: 0))
    TranscriptionIndicatorView(status: .optionKeyPressed, meter: .init(averagePower: 0, peakPower: 0))
    TranscriptionIndicatorView(status: .recording, meter: .init(averagePower: 0.5, peakPower: 0.5))
    TranscriptionIndicatorView(status: .transcribing, meter: .init(averagePower: 0, peakPower: 0))
    TranscriptionIndicatorView(status: .prewarming, meter: .init(averagePower: 0, peakPower: 0))
    TranscriptionIndicatorView(status: .enhancing, meter: .init(averagePower: 0, peakPower: 0))
  }
  .padding(40)
}