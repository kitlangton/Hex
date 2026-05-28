import Foundation
import SwiftUI

struct FileTranscriptionJob: Equatable, Identifiable {
  let id: UUID
  let url: URL
  let fileName: String
  var status: FileTranscriptionStatus = .queued
  var transcriptText: String?
  var transcriptID: UUID?
  var errorMessage: String?

  init(id: UUID = UUID(), url: URL) {
    self.id = id
    self.url = url
    self.fileName = url.lastPathComponent
  }
}

enum FileTranscriptionStatus: Equatable {
  case queued
  case transcribing
  case saving
  case completed
  case failed

  var title: String {
    switch self {
    case .queued:
      return "Queued"
    case .transcribing:
      return "Transcribing"
    case .saving:
      return "Saving"
    case .completed:
      return "Complete"
    case .failed:
      return "Failed"
    }
  }

  var systemImage: String {
    switch self {
    case .queued:
      return "clock"
    case .transcribing:
      return "waveform"
    case .saving:
      return "tray.and.arrow.down"
    case .completed:
      return "checkmark.circle.fill"
    case .failed:
      return "exclamationmark.triangle.fill"
    }
  }

  var tint: Color {
    switch self {
    case .queued, .saving:
      return .secondary
    case .transcribing:
      return .blue
    case .completed:
      return .green
    case .failed:
      return .red
    }
  }

  var isFinished: Bool {
    switch self {
    case .completed, .failed:
      return true
    case .queued, .transcribing, .saving:
      return false
    }
  }
}
