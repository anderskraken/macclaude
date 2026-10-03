import MacClaudeCore

struct AccountAvailability {
    static let checkedClaudeVersions: Set<String> = ["2.9939.4", "2.19675.0"]
    static var checkedClaudeVersionDescription: String { checkedClaudeVersions.sorted().joined(separator: " and ") }
    static func supportsTransfers(version: String?) -> Bool {
        version.map { checkedClaudeVersions.contains($0) } ?? false
    }

    let claudeVersion: String?
    let location: SessionLocation
    let profiles: [AccountProfile]

    var transfersSupported: Bool { Self.supportsTransfers(version: claudeVersion) }
    var owner: AccountProfile? { profiles.first { $0.id == location.ownerID } }

    var blockedReason: String? {
        guard let claudeVersion else { return "Choose the Claude app first." }
        return transfersSupported ? nil : "Switching isn’t available on Claude \(claudeVersion) yet."
    }

    func canOpen(_ profile: AccountProfile) -> Bool {
        guard claudeVersion != nil else { return false }
        return transfersSupported || (location.ownerID == profile.id && location.canReopen)
    }

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
