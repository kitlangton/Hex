//
//  CloudAccountStatus.swift
//  HexIOS
//
//  Surfaces the user's iCloud account state so Settings can tell them whether
//  history is actually syncing and, if not, how to fix it. (SwiftData's CloudKit
//  store silently runs local-only when there's no account; without this the user
//  has no idea sync is off.)
//

import CloudKit
import Foundation
import Observation

@MainActor
@Observable
final class CloudAccountStatus {
    enum State: Equatable {
        case unknown
        case available
        case noAccount
        case restricted
        case unavailable

        var isSyncing: Bool { self == .available }
    }

    private(set) var state: State = .unknown

    func refresh() async {
        do {
            switch try await CKContainer.default().accountStatus() {
            case .available: state = .available
            case .noAccount: state = .noAccount
            case .restricted: state = .restricted
            default: state = .unavailable
            }
        } catch {
            state = .unavailable
        }
    }
}
