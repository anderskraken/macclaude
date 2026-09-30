import Foundation

public struct AccountProfile: Codable, Equatable, Identifiable, Sendable {
    public static let defaultID = "default"

    public let id: String
    public var name: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString.lowercased(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }

    public var isDefault: Bool { id == Self.defaultID }

    public static var personal: AccountProfile {
        AccountProfile(id: defaultID, name: "Personal")
    }

    static func isValidManagedID(_ id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        return uuid.uuidString.lowercased() == id.lowercased()
    }
}

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var profiles: [AccountProfile]
    public var claudeApplicationPath: String?
    public var lastOpenedProfileID: String?

    public init(
        schemaVersion: Int = 1,
        profiles: [AccountProfile] = [.personal],
        claudeApplicationPath: String? = nil,
        lastOpenedProfileID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.claudeApplicationPath = claudeApplicationPath
        self.lastOpenedProfileID = lastOpenedProfileID
    }
}
