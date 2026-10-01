import Darwin
import Foundation

public enum ProfileStoreError: Error, LocalizedError, Equatable {
    case invalidConfiguration(String)
    case unsupportedSchema(Int)
    case unsafeStorage(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(reason):
            return "MacClaude’s account configuration is invalid: \(reason) The saved file has not been changed."
        case let .unsupportedSchema(version):
            return "This account configuration uses version \(version), which this version of MacClaude cannot read. The saved file has not been changed."
        case let .unsafeStorage(reason):
            return "MacClaude could not safely access its account configuration: \(reason)"
        }
    }
}

public struct ProfileStore: Sendable {
    public let rootDirectory: URL
    public var configurationURL: URL { rootDirectory.appendingPathComponent("config.json") }

    private static let maximumConfigurationSize = 1_048_576

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    public func load() throws -> AppConfiguration {
        let data: Data
        do {
            data = try BoundedFile.read(configurationURL, maximumBytes: Self.maximumConfigurationSize)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            // O_NOFOLLOW ensures a dangling symlink is not mistaken for a missing file.
            return AppConfiguration()
        }
        let configuration: AppConfiguration
        do {
            configuration = try Self.decoder().decode(AppConfiguration.self, from: data)
        } catch {
            throw ProfileStoreError.invalidConfiguration("config.json could not be decoded.")
        }
        try Self.validate(configuration)
        return configuration
    }

    public func save(_ configuration: AppConfiguration) throws {
        try Self.validate(configuration)
        // A caller must explicitly recover an unreadable configuration. A normal save
        // must never replace it with an empty or freshly initialized account list.
        _ = try load()
        let manager = FileManager.default
        try manager.createDirectory(at: rootDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try manager.attributesOfItem(atPath: rootDirectory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw ProfileStoreError.unsafeStorage("the storage folder is not a regular directory.")
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootDirectory.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        guard data.count <= Self.maximumConfigurationSize else {
            throw ProfileStoreError.invalidConfiguration("the account list is too large.")
        }
        try writeAtomically(data)
    }

    public static func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileStoreError.invalidConfiguration("account names cannot be empty.") }
        guard trimmed.count <= 60 else { throw ProfileStoreError.invalidConfiguration("account names must be 60 characters or fewer.") }
        guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw ProfileStoreError.invalidConfiguration("account names cannot contain control characters.")
        }
        return trimmed
    }

    private static func validate(_ configuration: AppConfiguration) throws {
        guard configuration.schemaVersion == 1 else { throw ProfileStoreError.unsupportedSchema(configuration.schemaVersion) }
        guard !configuration.profiles.isEmpty, configuration.profiles.count <= 1_000 else {
            throw ProfileStoreError.invalidConfiguration("the account list must contain between 1 and 1,000 entries.")
        }
        guard configuration.profiles.filter(\.isDefault).count == 1 else {
            throw ProfileStoreError.invalidConfiguration("the existing Claude account must appear exactly once.")
        }
        var identifiers: Set<String> = []
        for profile in configuration.profiles {
            guard profile.isDefault || AccountProfile.isValidManagedID(profile.id) else {
                throw ProfileStoreError.invalidConfiguration("an account identifier is not valid.")
            }
            guard identifiers.insert(profile.id.lowercased()).inserted else {
                throw ProfileStoreError.invalidConfiguration("account identifiers must be unique.")
            }
            guard profile.name == (try validatedName(profile.name)) else {
                throw ProfileStoreError.invalidConfiguration("account names cannot start or end with whitespace.")
            }
            guard profile.createdAt.timeIntervalSince1970.isFinite else {
                throw ProfileStoreError.invalidConfiguration("an account creation date is not valid.")
            }
        }
        if let applicationPath = configuration.claudeApplicationPath {
            guard applicationPath.hasPrefix("/"), !applicationPath.contains("\0") else {
                throw ProfileStoreError.invalidConfiguration("the Claude application path must be absolute.")
            }
        }
        if let lastOpenedID = configuration.lastOpenedProfileID {
            guard configuration.profiles.contains(where: { $0.id == lastOpenedID }) else {
                throw ProfileStoreError.invalidConfiguration("the last opened account is missing from the account list.")
            }
        }
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func writeAtomically(_ data: Data) throws {
        let temporaryURL = rootDirectory.appendingPathComponent(".config-\(UUID().uuidString).tmp")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        var descriptorOpen = true
        defer {
            if descriptorOpen { close(descriptor) }
            // Only remove this save's temporary file. Account data is never deleted.
            _ = unlink(temporaryURL.path)
        }
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: written), buffer.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else { throw ProfileStoreError.unsafeStorage("config.json could not be fully written.") }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else { throw posixError() }
        let closeResult = close(descriptor)
        descriptorOpen = false
        guard closeResult == 0 else { throw posixError() }
        guard rename(temporaryURL.path, configurationURL.path) == 0 else { throw posixError() }
        // Recovery checks journal profiles against this list, so the rename itself must survive power loss.
        let directory = open(rootDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw posixError() }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw posixError() }
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: configurationURL.path])
    }
}
