import MacClaudeCore

/// What the window and menu may offer, derived from the installed Claude and the
/// last session inspection. Launches always recheck the store themselves.
struct AccountAvailability {
    static let checkedClaudeVersion = "2.9939.4"

    let claudeVersion: String?
    let location: SessionLocation
    let profiles: [AccountProfile]

    var transfersSupported: Bool { claudeVersion == Self.checkedClaudeVersion }
    var owner: AccountProfile? { profiles.first { $0.id == location.ownerID } }

    var blockedReason: String? {
        guard let claudeVersion else { return "Choose the Claude app first." }
        return transfersSupported ? nil : "Switching isn’t available on Claude \(claudeVersion) yet."
    }

    func canOpen(_ profile: AccountProfile) -> Bool {
        guard claudeVersion != nil else { return false }
        return transfersSupported || (location.ownerID == profile.id && location.canReopen)
    }

    /// Shown only when the person has something to do or wait for.
    var banner: (text: String?, action: AccountNoticeAction?) {
        guard let claudeVersion else {
            return ("Claude wasn’t found.", .init(title: "Choose Claude App…", action: .chooseClaude))
        }
        switch location {
        case .checking:
            return (nil, nil)
        case .recoveryRequired:
            let next = transfersSupported ? "Choose an account to finish it." : "Update MacClaude to finish it on Claude \(claudeVersion)."
            return ("A switch was interrupted. Keep Claude closed. \(next)", .init(title: "Show Recovery Folder", action: .revealRecovery))
        case let .unavailable(error):
            return ("MacClaude couldn’t check where your sessions are. \(error.localizedDescription)",
                    .init(title: "Show Profile Folders", action: .revealProfiles))
        case .ready:
            guard !transfersSupported, let reason = blockedReason else { return (nil, nil) }
            guard let owner, location.canReopen else { return (reason, nil) }
            return ("\(reason) You can still open \(owner.name), which has your sessions.",
                    .init(title: "Open \(owner.name)", action: .open(owner.id)))
        }
    }
}
