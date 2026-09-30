import Foundation
import MacClaudeCore

/// An allowlist report: never serialize paths, account names, IDs, argv or errors.
struct DiagnosticsReport {
    let appVersion: String
    let build: String
    let claudeVersion: String?
    let profiles: [AccountProfile]
    let runningIDs: Set<String>
    let unidentifiedProcesses: Int
    let location: SessionLocation
    let transfersSupported: Bool
    let phase: SwitchPhase?
    let pendingID: String?
    let launchTimedOut: Bool
    let lastFailure: DiagnosticFailure?

    var text: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines = [
            "MacClaude diagnostics (account numbers match the Accounts window)",
            "MacClaude: \(Self.version(appVersion)) (\(Self.version(build)))",
            "macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "Claude: \(claudeVersion.map(Self.version) ?? "not found")",
            "Account transfers: \(transfersSupported ? "version checked" : "paused — version not checked")",
            "Stage: \(phase?.rawValue ?? "idle")",
            "Pending launch: \(account(pendingID))",
            "Launch exceeded 30 seconds: \(launchTimedOut ? "yes" : "no")"
        ]
        for (index, profile) in profiles.enumerated() {
            lines.append("Account \(index + 1)\(profile.isDefault ? " (original)" : ""): \(runningIDs.contains(profile.id) ? "running" : "closed")")
        }
        lines.append("Unidentified Claude processes: \(unidentifiedProcesses)")
        switch location {
        case .checking: lines.append("Session location: checking")
        case let .ready(ownerID, canReopen):
            lines.append("Session holder: \(account(ownerID))")
            lines.append("Reopen without transfer verified: \(canReopen ? "yes" : "no")")
            lines.append("Pending session recovery: no")
        case .recoveryRequired:
            lines.append("Session holder: transfer unfinished")
            lines.append("Pending session recovery: yes")
        case let .unavailable(error):
            lines.append("Session location: unavailable (\(Self.failureCode(error)))")
            lines.append("Pending session recovery: unknown")
        }
        // Callers supply only codes from failureCode, never localized descriptions.
        lines.append("Last failure: \(lastFailure?.code ?? "none recorded this run")")
        lines.append("No account names, paths, credentials or conversation contents included.")
        return lines.joined(separator: "\n")
    }

    private func account(_ id: String?) -> String {
        guard let id else { return "none" }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return "unknown" }
        return "Account \(index + 1)"
    }

    private static func version(_ value: String) -> String {
        guard !value.isEmpty, value.count <= 40, value.allSatisfy({ "0123456789.".contains($0) }) else { return "unknown" }
        return value
    }

    static func failureCode(_ error: Error) -> String {
        if let error = error as? RuntimeError {
            switch error {
            case .invalidApplication: return "invalid_application"
            case .applicationChanged: return "application_changed"
            case .unreadableInstances: return "unreadable_instances"
            case .launchDidNotMatch: return "launch_identity_unverified"
            case .launchTimedOut: return "launch_timeout"
            case .unsafeDirectory: return "unsafe_profile_directory"
            case .alreadyLaunching: return "launch_in_progress"
            case .quitRefused: return "quit_refused"
            case .processesStillRunning: return "processes_still_running"
            case .processInspectionFailed: return "process_inspection_failed"
            case .shutdownTimedOut: return "shutdown_timeout"
            }
        }
        if let error = error as? SharedSessionStoreError {
            switch error {
            case .unsafe: return "unsafe_session_storage"
            case .multipleHistories: return "multiple_histories"
            case .ambiguousNamespace: return "ambiguous_namespace"
            case .pendingImport: return "pending_import"
            case .recoveryRequired: return "recovery_required"
            case .changed: return "session_storage_changed"
            case .differentVolumes: return "different_volumes"
            case .conflictingWorktreePools: return "conflicting_worktree_pools"
            }
        }
        if error is SharedCompatibilityError { return "claude_version_unchecked" }
        return "system_error_\((error as NSError).code)"
    }
}

struct DiagnosticFailure {
    let code: String
    init(_ error: Error) { code = DiagnosticsReport.failureCode(error) }
}
