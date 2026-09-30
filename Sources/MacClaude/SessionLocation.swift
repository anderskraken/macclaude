import Foundation
import MacClaudeCore

/// A read-only snapshot for UI copy. Launches always recheck the store.
enum SessionLocation: Sendable {
    case checking
    case ready(ownerID: String?, canReopen: Bool)
    case recoveryRequired
    case unavailable(any Error)

    var ownerID: String? {
        if case let .ready(ownerID, _) = self { return ownerID }
        return nil
    }

    var canReopen: Bool {
        if case let .ready(_, canReopen) = self { return canReopen }
        return false
    }

    static func read(root: URL, profiles: [AccountProfile], paths: ProfilePaths) -> Self {
        do {
            let store = SharedSessionStore(rootDirectory: root)
            if try store.hasPendingTransaction() { return .recoveryRequired }
            let directories = profiles.map { paths.userDataDirectory(for: $0) }
            let inspection = try store.inspect(profileDirectories: directories)
            let owner = profiles.first { paths.userDataDirectory(for: $0) == inspection.activeProfileDirectory }
            let canReopen = try owner.map {
                try store.canReopenWithoutTransfer(profileDirectories: directories, destination: paths.userDataDirectory(for: $0))
            } ?? false
            return .ready(ownerID: owner?.id, canReopen: canReopen)
        } catch { return .unavailable(error) }
    }

    func outcome(startingOwnerID: String?, profiles: [AccountProfile]) -> String {
        switch self {
        case let .ready(ownerID?, _):
            guard let owner = profiles.first(where: { $0.id == ownerID }) else { return "" }
            if let startingOwnerID, startingOwnerID != ownerID {
                return "Your shared sessions are now in \(owner.name). Opening that account uses the sessions at their current location."
            }
            return "Your shared sessions remain in \(owner.name)."
        case .recoveryRequired:
            return "A session transfer is unfinished. MacClaude kept its recovery information. Recovery must complete before an account can open."
        case .unavailable:
            return "The current session location could not be verified. Do not restore an older backup over your current work."
        case .checking, .ready(nil, _): return ""
        }
    }
}
