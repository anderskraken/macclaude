import Darwin
import Foundation

public enum SessionWriterGuardError: Error, LocalizedError, Equatable, Sendable {
    case activeWriter
    case unreadableRegistry
    case invalidLiveRegistryEntry
    case unreadableSessionMetadata
    case scanLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .activeWriter:
            return "A Claude Code process is still using this history. Quit that process before switching accounts."
        case .unreadableRegistry:
            return "Claude Code’s process registry could not be checked. The switch stopped to protect your sessions."
        case .invalidLiveRegistryEntry:
            return "A running Claude Code process has an unreadable or unfamiliar registry entry. Quit it before switching accounts."
        case .unreadableSessionMetadata:
            return "The session history could not be checked for running Claude Code processes. The switch stopped to protect your sessions."
        case .scanLimitExceeded:
            return "The Claude Code process check exceeded its safe reading limit. The switch stopped to protect your sessions."
        }
    }
}

/// Checks metadata only; does not read transcripts, credentials, or registry
/// socket contents. The caller must stop Desktop and collect a fresh process
/// snapshot first. This check cannot lock out a new writer after it returns.
public enum SessionWriterGuard {
    private static let maximumDirectoryEntries = 50_000
    private static let maximumRegistryBytes = 1_048_576
    private static let maximumRecordBytes = 10_485_760
    private static let maximumTotalBytes = 67_108_864
    private static let maximumLineageIDs = 10_000

    public static func check(
        sessionDirectory: URL?,
        configDirectory: URL,
        liveProcessIDs: Set<Int32>
    ) throws {
        var totalBytes = 0
        let liveSessionIDs = try registeredSessions(configDirectory: configDirectory,
                                                    liveProcessIDs: liveProcessIDs, totalBytes: &totalBytes)
        guard !liveSessionIDs.isEmpty, let sessionDirectory else { return }
        guard let sessionFD = try openDirectory(sessionDirectory, allowMissing: false, failure: .unreadableSessionMetadata) else {
            throw SessionWriterGuardError.unreadableSessionMetadata
        }
        defer { close(sessionFD) }
        var totalEntries = 0
        try checkHistory(sessionFD, liveSessionIDs: liveSessionIDs, totalBytes: &totalBytes, totalEntries: &totalEntries)
    }

    /// Looks in both possible owners during a journaled transfer. Missing
    /// namespaces are expected between renames; existing namespace directories
    /// must be real directories. The caller validates profile ownership and
    /// transaction state separately before performing any mutation.
    public static func check(
        profileDirectories: [URL],
        configDirectory: URL,
        liveProcessIDs: Set<Int32>
    ) throws {
        var totalBytes = 0
        let liveSessionIDs = try registeredSessions(configDirectory: configDirectory,
                                                    liveProcessIDs: liveProcessIDs, totalBytes: &totalBytes)
        guard !liveSessionIDs.isEmpty else { return }
        guard profileDirectories.count <= 128 else { throw SessionWriterGuardError.scanLimitExceeded }
        var namespaceEntries = 0
        for profile in profileDirectories {
            guard let profileFD = try openDirectory(profile, allowMissing: true, failure: .unreadableSessionMetadata) else { continue }
            defer { close(profileFD) }
            guard let rootFD = try openDirectory("claude-code-sessions", in: profileFD, allowMissing: true) else { continue }
            defer { close(rootFD) }
            let accounts = try namespaceNames(in: rootFD, entryCount: &namespaceEntries)
            for account in accounts where canonicalUUID(account) != nil {
                guard let accountFD = try openDirectory(account, in: rootFD, allowMissing: true) else { continue }
                defer { close(accountFD) }
                let organizations = try namespaceNames(in: accountFD, entryCount: &namespaceEntries)
                for organization in organizations where canonicalUUID(organization) != nil {
                    guard let organizationFD = try openDirectory(organization, in: accountFD, allowMissing: true) else { continue }
                    defer { close(organizationFD) }
                    try checkHistory(organizationFD, liveSessionIDs: liveSessionIDs, totalBytes: &totalBytes, totalEntries: &namespaceEntries)
                }
            }
        }
    }

    private static func registeredSessions(configDirectory: URL, liveProcessIDs: Set<Int32>,
                                           totalBytes: inout Int) throws -> Set<String> {
        let registry = configDirectory.appendingPathComponent("sessions", isDirectory: true)
        guard let registryFD = try openDirectory(registry, allowMissing: true, failure: .unreadableRegistry) else { return [] }
        defer { close(registryFD) }
        var liveSessionIDs = Set<String>()
        for name in try names(in: registryFD, failure: .unreadableRegistry) {
            guard let pid = registryPID(name), liveProcessIDs.contains(pid) else { continue }
            let data = try read(name, in: registryFD, maximumBytes: maximumRegistryBytes,
                                failure: .invalidLiveRegistryEntry)
            try accountForBytes(data.count, total: &totalBytes)
            guard let entry = try? JSONDecoder().decode(RegistryEntry.self, from: data),
                  entry.pid == pid, let sessionID = canonicalUUID(entry.sessionId),
                  entry.kind.map({ $0.utf8.count <= 128 }) ?? true,
                  entry.procStart.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
                  validTimestamp(entry.startedAt), validTimestamp(entry.updatedAt) else {
                throw SessionWriterGuardError.invalidLiveRegistryEntry
            }
            liveSessionIDs.insert(sessionID)
        }
        return liveSessionIDs
    }

    private static func namespaceNames(in descriptor: Int32, entryCount: inout Int) throws -> [String] {
        let result = try names(in: descriptor, failure: .unreadableSessionMetadata)
        guard result.count <= maximumDirectoryEntries - entryCount else { throw SessionWriterGuardError.scanLimitExceeded }
        entryCount += result.count
        return result
    }

    private static func checkHistory(_ sessionFD: Int32, liveSessionIDs: Set<String>, totalBytes: inout Int,
                                     totalEntries: inout Int) throws {
        for name in try namespaceNames(in: sessionFD, entryCount: &totalEntries)
        where name.hasPrefix("local_") && name.hasSuffix(".json") {
            let data = try read(name, in: sessionFD, maximumBytes: maximumRecordBytes,
                                failure: .unreadableSessionMetadata)
            try accountForBytes(data.count, total: &totalBytes)
            guard let record = try? JSONDecoder().decode(SessionRecord.self, from: data),
                  record.sessionId.hasPrefix("local_"), record.sessionId.utf8.count <= 128 else {
                throw SessionWriterGuardError.unreadableSessionMetadata
            }
            var owned = Set<String>()
            // Native and CLI identities differ; both native stems can also be
            // historical transcript IDs, even after clear or rewind.
            for nativeID in [String(name.dropLast(5)), record.sessionId] {
                if let id = canonicalUUID(String(nativeID.dropFirst(6))) { owned.insert(id) }
            }
            for value in [record.cliSessionId, record.unarchivedCliSessionId, record.preClearCliSessionId] {
                if let value { try insertUUID(value, into: &owned) }
            }
            let prior = record.priorCliSessionIds ?? []
            let edges = record.rewindEdges ?? []
            guard prior.count <= maximumLineageIDs, edges.count <= maximumLineageIDs else {
                throw SessionWriterGuardError.scanLimitExceeded
            }
            for id in prior { try insertUUID(id, into: &owned) }
            for edge in edges {
                try insertUUID(edge.parent, into: &owned)
                try insertUUID(edge.child, into: &owned)
            }
            // These maps are indexed by transcript ID; their values contain
            // message/model state, which the guard neither decodes nor exposes.
            for id in record.transcriptCuts?.keys ?? [] {
                try insertUUID(id, into: &owned)
            }
            for id in record.transcriptModelStates?.keys ?? [] {
                try insertUUID(id, into: &owned)
            }
            guard owned.isDisjoint(with: liveSessionIDs) else { throw SessionWriterGuardError.activeWriter }
        }
    }

    private static func validTimestamp(_ value: Double?) -> Bool {
        value.map { $0.isFinite && $0 >= 0 } ?? true
    }

    private static func canonicalUUID(_ value: String) -> String? {
        guard value.utf8.count == 36 else { return nil }
        return UUID(uuidString: value)?.uuidString.lowercased()
    }

    private static func insertUUID(_ value: String, into ids: inout Set<String>) throws {
        guard let id = canonicalUUID(value) else { throw SessionWriterGuardError.unreadableSessionMetadata }
        ids.insert(id)
    }

    private static func registryPID(_ name: String) -> Int32? {
        guard name.hasSuffix(".json") else { return nil }
        let digits = name.dropLast(5)
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let pid = Int32(digits), pid > 1 else { return nil }
        return pid
    }

    private static func accountForBytes(_ count: Int, total: inout Int) throws {
        guard count <= maximumTotalBytes - total else { throw SessionWriterGuardError.scanLimitExceeded }
        total += count
    }

    private static func openDirectory(_ url: URL, allowMissing: Bool, failure: SessionWriterGuardError) throws -> Int32? {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if allowMissing && errno == ENOENT { return nil }
            throw failure
        }
        return descriptor
    }

    private static func openDirectory(_ name: String, in parent: Int32, allowMissing: Bool) throws -> Int32? {
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if allowMissing && errno == ENOENT { return nil }
            throw SessionWriterGuardError.unreadableSessionMetadata
        }
        return descriptor
    }

    private static func names(in descriptor: Int32, failure: SessionWriterGuardError) throws -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw failure }
        guard let directory = fdopendir(copy) else {
            close(copy)
            throw failure
        }
        defer { closedir(directory) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw failure }
                return result
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            guard result.count < maximumDirectoryEntries else { throw SessionWriterGuardError.scanLimitExceeded }
            result.append(name)
        }
    }

    private static func read(_ name: String, in directory: Int32, maximumBytes: Int,
                             failure: SessionWriterGuardError) throws -> Data {
        // openat anchors every leaf to the already-open directory even if its
        // pathname is replaced while the process check runs.
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size >= 0, before.st_size <= maximumBytes else { throw failure }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= maximumBytes {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, maximumBytes + 1 - data.count))
            if count < 0 {
                if errno == EINTR { continue }
                throw failure
            }
            if count == 0 {
                var after = stat()
                var named = stat()
                guard fstat(descriptor, &after) == 0, before.st_size == after.st_size,
                      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                      fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      named.st_dev == after.st_dev, named.st_ino == after.st_ino,
                      named.st_mode & S_IFMT == S_IFREG,
                      data.count == after.st_size else { throw failure }
                return data
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        throw failure
    }

    private struct RegistryEntry: Decodable {
        let pid: Int32
        let sessionId: String
        let kind: String?
        let procStart: String?
        let startedAt: Double?
        let updatedAt: Double?
        let bridgeSessionId: String?
        let messagingSocketPath: String?
    }

    private struct SessionRecord: Decodable {
        let sessionId: String
        let cliSessionId: String?
        let unarchivedCliSessionId: String?
        let preClearCliSessionId: String?
        let priorCliSessionIds: [String]?
        let rewindEdges: [RewindEdge]?
        let transcriptCuts: KeyOnlyMap?
        let transcriptModelStates: KeyOnlyMap?
    }

    private struct RewindEdge: Decodable {
        let parent: String
        let child: String
    }

    private struct KeyOnlyMap: Decodable {
        let keys: [String]
        private struct Key: CodingKey {
            let stringValue: String
            let intValue: Int? = nil
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            guard container.allKeys.count <= SessionWriterGuard.maximumLineageIDs else {
                throw SessionWriterGuardError.scanLimitExceeded
            }
            keys = container.allKeys.map(\.stringValue)
        }
    }
}
