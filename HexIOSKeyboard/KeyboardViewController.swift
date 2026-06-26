//
//  KeyboardViewController.swift
//  HexIOSKeyboard
//
//  Mic-centric dictation keyboard. The keyboard itself never records (iOS blocks
//  mic access in keyboard extensions); tapping the mic bounces to the host app
//  via a custom URL, the host app records + transcribes and writes the result to
//  the shared App Group mailbox, and on returning here we insert it.
//

import HexCore
import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private let ipc = KeyboardIPC(appGroupIdentifier: HexAppGroup.identifier)
    private let state = KeyboardState()

    private var lastInsertedID: UUID?
    private var resultObserver: DarwinSignalObserver?
    private var observerTask: Task<Void, Never>?

    /// Don't insert a result older than this (avoids surfacing a stale, never-consumed transcript).
    private let resultFreshnessWindow: TimeInterval = 300

    override func viewDidLoad() {
        super.viewDidLoad()

        state.needsNextKeyboard = needsInputModeSwitchKey
        state.hasFullAccess = hasFullAccess

        let root = KeyboardView(
            state: state,
            onMic: { [weak self] in self?.startDictation() },
            onDelete: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            onNextKeyboard: { [weak self] in self?.advanceToNextInputMode() }
        )

        let hosting = UIHostingController(rootView: root)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.backgroundColor = .clear
        addChild(hosting)
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)

        let height = view.heightAnchor.constraint(equalToConstant: 240)
        height.priority = .defaultHigh
        height.isActive = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        state.hasFullAccess = hasFullAccess
        insertPendingResult()
        startObservingResults()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        observerTask?.cancel()
        observerTask = nil
        resultObserver = nil
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        state.needsNextKeyboard = needsInputModeSwitchKey
    }

    // MARK: - Actions

    private func startDictation() {
        guard hasFullAccess else {
            state.statusText = "Enable Full Access (Settings ▸ Keyboards) to dictate."
            return
        }
        guard let url = URL(string: "hexkb://dictate") else { return }
        state.statusText = "Opening Hex…"
        openHostApp(url)
    }

    // MARK: - Result delivery

    private func startObservingResults() {
        guard observerTask == nil else { return }
        let observer = DarwinSignalObserver([.resultReady])
        resultObserver = observer
        observerTask = Task { [weak self] in
            for await _ in observer.stream() {
                await MainActor.run { self?.insertPendingResult() }
            }
        }
    }

    private func insertPendingResult() {
        guard hasFullAccess, let ipc, let result = try? ipc.resultMailbox.read() else { return }
        guard result.id != lastInsertedID else { return }
        guard Date().timeIntervalSince(result.createdAt) < resultFreshnessWindow else {
            ipc.resultMailbox.clear()
            return
        }
        textDocumentProxy.insertText(result.text)
        lastInsertedID = result.id
        ipc.resultMailbox.clear()
        state.statusText = "Inserted."
    }

    // MARK: - Bounce

    /// Opens the host app from the extension. Walking the responder chain to a
    /// `openURL:`-responding object is unsupported by Apple but the standard way
    /// keyboards launch their container; it requires Full Access. Isolated here so
    /// there's a single place to fix if a future iOS changes the behavior.
    private func openHostApp(_ url: URL) {
        var responder: UIResponder? = self
        let selector = NSSelectorFromString("openURL:")
        while let current = responder {
            if current.responds(to: selector) {
                current.perform(selector, with: url)
                return
            }
            responder = current.next
        }
    }
}
