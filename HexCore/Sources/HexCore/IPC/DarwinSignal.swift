//
//  DarwinSignal.swift
//  HexCore
//
//  Thin wrapper over Darwin notifications (CFNotificationCenter's Darwin notify
//  center) for cross-process signaling between the keyboard extension and the
//  host app. Darwin notifications carry no payload — they only say "something
//  named X happened"; the actual data travels through AppGroupMailbox.
//

import Foundation

public enum DarwinSignal {
    /// Broadcast `signal` to all processes observing it.
    public static func post(_ signal: IPCSignal) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(signal.rawValue as CFString),
            nil,
            nil,
            true
        )
    }
}

/// Observes one or more `IPCSignal`s and yields them as an `AsyncStream`.
///
/// Darwin's C callback is a bare function pointer with no usable context, so we
/// route deliveries through an in-process `NotificationCenter` keyed by the
/// signal name: the C callback re-posts locally, and this observer listens for
/// that local notification. One Darwin registration per signal, kept alive for
/// the lifetime of the observer.
public final class DarwinSignalObserver: @unchecked Sendable {
    private let signals: [IPCSignal]
    private var tokens: [NSObjectProtocol] = []

    public init(_ signals: [IPCSignal]) {
        self.signals = signals
    }

    /// Begin observing; the returned stream yields each signal as it arrives.
    public func stream() -> AsyncStream<IPCSignal> {
        AsyncStream { continuation in
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            let local = NotificationCenter.default

            for signal in signals {
                // 1) Darwin -> local NotificationCenter bridge.
                CFNotificationCenterAddObserver(
                    center,
                    Unmanaged.passUnretained(self).toOpaque(),
                    { _, _, name, _, _ in
                        guard let raw = name?.rawValue as String? else { return }
                        NotificationCenter.default.post(name: Notification.Name(raw), object: nil)
                    },
                    signal.rawValue as CFString,
                    nil,
                    .deliverImmediately
                )

                // 2) local NotificationCenter -> AsyncStream.
                let token = local.addObserver(
                    forName: Notification.Name(signal.rawValue),
                    object: nil,
                    queue: nil
                ) { _ in
                    continuation.yield(signal)
                }
                tokens.append(token)
            }

            continuation.onTermination = { [weak self] _ in
                self?.tearDown()
            }
        }
    }

    private func tearDown() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens.removeAll()
    }

    deinit {
        tearDown()
    }
}
