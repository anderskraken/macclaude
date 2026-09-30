import Foundation

public struct LocalUsageSnapshot: Equatable, Sendable {
    public let observedAt: Date
    public let sessionPercent: Double?
    public let weeklyPercent: Double?

    public init(observedAt: Date, sessionPercent: Double?, weeklyPercent: Double?) {
        self.observedAt = observedAt
        self.sessionPercent = sessionPercent
        self.weeklyPercent = weeklyPercent
    }

    public func isStale(at date: Date = Date(), maximumAge: TimeInterval = 900) -> Bool {
        let age = date.timeIntervalSince(observedAt)
        return !age.isFinite || age < 0 || age > max(0, maximumAge)
    }
}

/// Reads only Claude's local, noncredential usage history. This is a recorded
/// observation, not a live quota check; no reset times or account identity are inferred.
public enum LocalUsageReader {
    public static let historyFilename = "plan-usage-history.json"
    private static let maximumFileSize = 2_097_152
    private static let maximumSampleCount = 10_000

    public static func read(from userDataDirectory: URL, now: Date = Date()) -> LocalUsageSnapshot? {
        let file = userDataDirectory.appendingPathComponent(historyFilename)
        guard let data = try? BoundedFile.read(file, maximumBytes: maximumFileSize), !data.isEmpty,
              let history = try? JSONDecoder().decode(History.self, from: data),
              history.version == 2,
              !history.samples.isEmpty, history.samples.count <= maximumSampleCount else { return nil }

        // Multiple organizations cannot be mapped to the active account safely from
        // this file alone. Omit usage instead of presenting another organization's quota.
        let organizations = Set(history.samples.map(\.org))
        guard organizations.count == 1 else { return nil }
        for sample in history.samples {
            guard sample.t.isFinite, sample.t > 0,
                  sample.t / 1_000 <= now.timeIntervalSince1970,
                  sample.u.values.allSatisfy({ $0.isFinite && (0...100).contains($0) }) else { return nil }
        }
        guard let latest = history.samples.max(by: { $0.t < $1.t }),
              latest.u["fh"] != nil || latest.u["sd"] != nil else { return nil }
        return LocalUsageSnapshot(
            observedAt: Date(timeIntervalSince1970: latest.t / 1_000),
            sessionPercent: latest.u["fh"],
            weeklyPercent: latest.u["sd"]
        )
    }

    private struct History: Decodable {
        let version: Int
        let samples: [Sample]
    }

    private struct Sample: Decodable {
        let t: Double
        let org: String?
        let u: [String: Double]

        private enum CodingKeys: String, CodingKey { case t, org, u }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            t = try container.decode(Double.self, forKey: .t)
            // Null is an observed organization value; an absent field is an unfamiliar schema.
            org = try container.decode(String?.self, forKey: .org)
            u = try container.decode([String: Double].self, forKey: .u)
        }
    }
}
