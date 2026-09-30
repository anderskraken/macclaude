import Foundation
import MacClaudeCore

struct UsagePresentation {
    let amounts: String
    let recorded: String
    let isStale: Bool
    var text: String { amounts + "\n" + recorded }

    init(_ snapshot: LocalUsageSnapshot, now: Date = Date()) {
        var parts: [String] = []
        if let value = snapshot.sessionPercent { parts.append("5h: \(Int(value.rounded()))% used") }
        if let value = snapshot.weeklyPercent { parts.append("Week: \(Int(value.rounded()))% used") }
        amounts = parts.joined(separator: " · ")
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        isStale = snapshot.isStale(at: now)
        recorded = "Recorded " + formatter.localizedString(for: snapshot.observedAt, relativeTo: now) + (isStale ? " · stale" : "")
    }
}
