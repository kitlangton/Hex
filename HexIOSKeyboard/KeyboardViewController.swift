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
    private var isCapturing = false

    /// Drives the once-per-second `state.clock` tick so the "MM:SS left" pill and
    /// the session-expiry phase update live without a re-bounce.
    private var clockTimer: Timer?

    /// Auto-clears the brief "Inserted" confirmation (the .inserting state).
    private var insertConfirmationTask: Task<Void, Never>?

    /// Don't insert a result older than this (avoids surfacing a stale, never-consumed transcript).
    private let resultFreshnessWindow: TimeInterval = 300

    override func viewDidLoad() {
        super.viewDidLoad()

        state.needsNextKeyboard = needsInputModeSwitchKey
        state.hasFullAccess = hasFullAccess

        let actions = KeyboardActions(
            onMic: { [weak self] in self?.handleMicTap() },
            onDelete: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            onNextKeyboard: { [weak self] in self?.advanceToNextInputMode() },
            onSpace: { [weak self] in self?.textDocumentProxy.insertText(" ") },
            onReturn: { [weak self] in self?.textDocumentProxy.insertText("\n") },
            onDeleteWord: { [weak self] in self?.deleteWordBackward() },
            onCaretMove: { [weak self] offset in self?.textDocumentProxy.adjustTextPosition(byCharacterOffset: offset) },
            onInsert: { [weak self] text in self?.textDocumentProxy.insertText(text) },
            onUndo: { [weak self] in self?.performUndoAction(redo: false) },
            onRedo: { [weak self] in self?.performUndoAction(redo: true) }
        )

        let root = KeyboardView(state: state, actions: actions)

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

        let height = view.heightAnchor.constraint(equalToConstant: 268)
        height.priority = .defaultHigh
        height.isActive = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        state.hasFullAccess = hasFullAccess
        // With Full Access we can touch the App Group — record presence + signal
        // so the host app's onboarding can confirm the keyboard is set up.
        if hasFullAccess {
            KeyboardPresence.markActive(appGroupIdentifier: HexAppGroup.identifier)
            DarwinSignal.post(.keyboardActive)
        }
        refreshSessionState()
        insertPendingResult()
        startObservingResults()
        startClock()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        observerTask?.cancel()
        observerTask = nil
        resultObserver = nil
        clockTimer?.invalidate()
        clockTimer = nil
        insertConfirmationTask?.cancel()
        insertConfirmationTask = nil
    }

    /// One cheap timer drives the live countdown + expiry transition. No model,
    /// no audio — keeps the extension memory-light.
    private func startClock() {
        clockTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.state.clock = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        state.needsNextKeyboard = needsInputModeSwitchKey
    }

    // MARK: - Actions

    /// If a Flow Session is active, toggle capture in place (no bounce). Otherwise
    /// bounce once to the host app to start a session.
    private func handleMicTap() {
        guard hasFullAccess else {
            state.statusText = "Enable Full Access (Settings ▸ Keyboards) to dictate."
            return
        }
        // Any user-initiated tap clears a stale error/confirmation so the UI
        // reflects the action they just took.
        state.errorMessage = nil
        state.justInserted = false
        // Re-read liveness fresh on every tap; a session can have died (app
        // crashed/suspended) since we last refreshed, leaving a stale "active" flag.
        let session = currentSession()
        let usable = session?.isUsable(at: Date()) == true
        state.sessionActive = usable
        state.sessionExpiresAt = usable ? session?.expiresAt : nil
        if usable {
            toggleCapture()
        } else {
            // Session is dead/stale — reset any stuck capturing state and bounce
            // to start a fresh one instead of posting into the void.
            isCapturing = false
            state.isCapturing = false
            startSessionBounce()
        }
    }

    private func toggleCapture() {
        if isCapturing {
            DarwinSignal.post(.captureStop)
            isCapturing = false
            state.statusText = "Transcribing…"
        } else {
            DarwinSignal.post(.captureStart)
            isCapturing = true
            state.statusText = "Listening… tap to stop"
        }
        state.isCapturing = isCapturing
    }

    private func startSessionBounce() {
        guard let url = URL(string: "hexkb://startSession") else { return }
        state.statusText = "Starting session in Hex…"
        guard let application = firstUIApplicationInResponderChain() else {
            state.errorMessage = "Couldn't reach Hex. Open the app once, then try again."
            state.statusText = "Couldn't reach the app (no UIApplication in chain)."
            return
        }
        application.open(url, options: [:]) { [weak self] success in
            if !success {
                self?.state.errorMessage = "iOS blocked opening Hex."
                self?.state.statusText = "iOS blocked opening Hex."
            }
        }
    }

    private func currentSession() -> DictationSessionState? {
        guard let ipc else { return nil }
        return try? ipc.sessionMailbox.read()
    }

    // MARK: - Result + session signals

    private func startObservingResults() {
        guard observerTask == nil else { return }
        let observer = DarwinSignalObserver([.resultReady, .sessionChanged])
        resultObserver = observer
        observerTask = Task { [weak self] in
            for await signal in observer.stream() {
                await MainActor.run {
                    switch signal {
                    case .resultReady: self?.insertPendingResult()
                    case .sessionChanged: self?.refreshSessionState()
                    default: break
                    }
                }
            }
        }
    }

    private func refreshSessionState() {
        let session = currentSession()
        let active = session?.isUsable(at: Date()) == true
        state.sessionActive = active
        state.sessionExpiresAt = active ? session?.expiresAt : nil
        if !active {
            isCapturing = false
            state.isCapturing = false
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
        isCapturing = false
        state.isCapturing = false
        state.errorMessage = nil
        state.statusText = state.sessionActive ? "Inserted — tap to dictate again." : "Inserted."
        flashInsertedConfirmation()
    }

    /// Shows the brief ".inserting" confirmation state, then returns to idle.
    private func flashInsertedConfirmation() {
        insertConfirmationTask?.cancel()
        state.justInserted = true
        insertConfirmationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.state.justInserted = false }
        }
    }

    // MARK: - Editing controls (P2-5)

    /// Deletes back to the previous word boundary using the text *before* the
    /// caret, mirroring the system "delete word" behavior. Falls back to a single
    /// `deleteBackward` when the context is unavailable.
    private func deleteWordBackward() {
        guard let before = textDocumentProxy.documentContextBeforeInput, !before.isEmpty else {
            textDocumentProxy.deleteBackward()
            return
        }
        // Count trailing whitespace, then the word characters before it.
        var deleteCount = 0
        let reversed = Array(before.reversed())
        var index = 0
        while index < reversed.count, reversed[index].isWhitespace {
            deleteCount += 1
            index += 1
        }
        while index < reversed.count, !reversed[index].isWhitespace {
            deleteCount += 1
            index += 1
        }
        if deleteCount == 0 { deleteCount = 1 }
        for _ in 0 ..< deleteCount { textDocumentProxy.deleteBackward() }
    }

    /// Best-effort undo/redo by walking the responder chain for the host text
    /// view's `UIUndoManager`. No-ops silently if the host doesn't expose one —
    /// undo/redo from a keyboard extension isn't guaranteed.
    private func performUndoAction(redo: Bool) {
        var responder: UIResponder? = self
        while let current = responder {
            if let manager = current.undoManager {
                if redo {
                    if manager.canRedo { manager.redo() }
                } else {
                    if manager.canUndo { manager.undo() }
                }
                return
            }
            responder = current.next
        }
    }

    // MARK: - Bounce

    /// Opens the host app from the extension by finding `UIApplication` in the
    /// responder chain and calling the modern `open(_:options:completionHandler:)`.
    /// (The old `openURL:` selector hack no-ops on recent iOS.) Unsupported by
    /// Apple but the standard way keyboards launch their container; requires Full
    /// Access. Returns whether a UIApplication was found. Isolated here so there's
    /// one place to fix if a future iOS changes the behavior.
    private func firstUIApplicationInResponderChain() -> UIApplication? {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication { return application }
            responder = current.next
        }
        return nil
    }
}
