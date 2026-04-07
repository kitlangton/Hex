import Darwin
import Foundation

final class CLIStopMonitor: @unchecked Sendable {
  enum Trigger: Equatable {
    case enter
    case sigint
  }

  private let state = State()
  private let queue = DispatchQueue(label: "HexCLI.stop-monitor")
  private let signalSource: DispatchSourceSignal
  private let stdinSource: DispatchSourceRead
  private var isCancelled = false

  init() {
    signal(SIGINT, SIG_IGN)

    signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
    stdinSource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: queue)

    signalSource.setEventHandler { [state] in
      Task {
        await state.finish(with: .sigint)
      }
    }

    stdinSource.setEventHandler { [state, stdinSource] in
      let bytesToRead = max(Int(stdinSource.data), 1)
      var buffer = [UInt8](repeating: 0, count: bytesToRead)
      let readCount = Darwin.read(STDIN_FILENO, &buffer, bytesToRead)

      if readCount == 0 {
        Task {
          await state.finish(with: .enter)
        }
        return
      }

      if readCount < 0 {
        return
      }

      let received = buffer.prefix(readCount)
      if received.contains(10) || received.contains(13) {
        Task {
          await state.finish(with: .enter)
        }
      }
    }

    signalSource.resume()
    stdinSource.resume()
  }

  deinit {
    cancel()
  }

  func waitForStop() async -> Trigger {
    await state.wait()
  }

  func cancel() {
    guard !isCancelled else {
      return
    }

    isCancelled = true
    stdinSource.cancel()
    signalSource.cancel()
    signal(SIGINT, SIG_DFL)
  }
}

private actor State {
  private var continuation: CheckedContinuation<CLIStopMonitor.Trigger, Never>?
  private var result: CLIStopMonitor.Trigger?

  func wait() async -> CLIStopMonitor.Trigger {
    if let result {
      return result
    }

    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func finish(with result: CLIStopMonitor.Trigger) {
    guard self.result == nil else {
      return
    }

    self.result = result
    continuation?.resume(returning: result)
    continuation = nil
  }
}
