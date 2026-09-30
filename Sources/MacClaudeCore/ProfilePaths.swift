import Darwin
import Foundation

public struct ProfilePaths: Sendable {
    public let rootDirectory: URL
    public let homeDirectory: URL

    public init(rootDirectory: URL, homeDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    public func userDataDirectory(for profile: AccountProfile) -> URL {
        if profile.isDefault {
            return homeDirectory.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        }
        // The store rejects invalid identifiers. Keep this public path helper contained
        // even when handed an unvalidated, externally constructed profile.
        let component = AccountProfile.isValidManagedID(profile.id) ? profile.id.lowercased() : ".invalid-profile"
        return rootDirectory.appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
    }

    public func launchArguments(for profile: AccountProfile) -> [String] {
        profile.isDefault ? [] : ["--user-data-dir=\(userDataDirectory(for: profile).path)"]
    }
}

public enum InstanceProfile: Equatable, Sendable {
    case defaultProfile
    case directory(String)
    case unknown

    /// Classify actual argv, never a shell command string. Ambiguous switches fail closed.
    public static func classify(arguments: [String]?) -> InstanceProfile {
        guard let arguments else { return .unknown }
        var directory: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let value: String?
            if argument == "--user-data-dir" {
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--") else { return .unknown }
                value = arguments[index]
            } else if argument.hasPrefix("--user-data-dir=") {
                value = String(argument.dropFirst("--user-data-dir=".count))
            } else {
                value = nil
            }
            if let value {
                guard let normalized = normalizedDirectory(value) else { return .unknown }
                if let directory, !sameDirectory(directory, normalized) { return .unknown }
                directory = normalized
            }
            index += 1
        }
        return directory.map(InstanceProfile.directory) ?? .defaultProfile
    }

    public func matches(profile: AccountProfile, paths: ProfilePaths) -> Bool {
        guard profile.isDefault || AccountProfile.isValidManagedID(profile.id) else { return false }
        switch self {
        case .defaultProfile:
            return profile.isDefault
        case let .directory(directory):
            guard let directory = Self.normalizedDirectory(directory) else { return false }
            let expected = paths.userDataDirectory(for: profile).path
            return Self.sameDirectory(directory, expected)
        case .unknown:
            return false
        }
    }

    private static func normalizedDirectory(_ value: String) -> String? {
        // Relative paths cannot be interpreted without the other process's cwd.
        guard value.hasPrefix("/"), !value.contains("\0") else { return nil }
        // Resolve before standardizing: collapsing symlink/.. lexically can identify
        // a different directory from the one the operating system actually opens.
        if let resolved = realpath(value, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: value, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func identity(of path: String) -> DirectoryIdentity? {
        var status = stat()
        guard fstatat(AT_FDCWD, path, &status, 0) == 0 else { return nil }
        return DirectoryIdentity(device: status.st_dev, inode: status.st_ino, isDirectory: status.st_mode & S_IFMT == S_IFDIR)
    }

    private static func sameDirectory(_ lhs: String, _ rhs: String) -> Bool {
        let leftIdentity = identity(of: lhs)
        let rightIdentity = identity(of: rhs)
        guard leftIdentity?.isDirectory != false, rightIdentity?.isDirectory != false else { return false }
        if let leftIdentity, let rightIdentity {
            // Device + inode recognizes case-insensitive aliases and symlinks even
            // when their textual paths differ. Only directories can identify a profile.
            return leftIdentity == rightIdentity
        }
        return normalizedDirectory(lhs) == normalizedDirectory(rhs)
    }

    private struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let isDirectory: Bool
    }
}
