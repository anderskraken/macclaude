import Darwin
import Foundation

public struct SharedSessionInspection: Sendable {
    public let masterDirectory: URL?
    public let activeProfileDirectory: URL?
    public let uninitializedProfiles: [URL]
    public let canActivate: Bool
}

public struct SharedSessionActivation: Sendable {
    public let didMove: Bool
    public let destinationNeedsSetup: Bool
    public let backupDirectory: URL?
}

public enum SharedSessionStoreError: Error, LocalizedError {
    case unsafe(String)
    case multipleHistories
    case ambiguousNamespace
    case pendingImport
    case recoveryRequired
    case changed
    case differentVolumes
    case conflictingWorktreePools

    public var errorDescription: String? {
        switch self {
        case let .unsafe(reason): return "Shared Code sessions could not be prepared: \(reason)"
        case .multipleHistories: return "More than one account has its own Code history. MacClaude has left both histories untouched."
        case .ambiguousNamespace: return "An account has more than one Code account or organization folder. MacClaude cannot safely choose which history to share."
        case .pendingImport: return "Finish the pending Code session import in Claude, then quit Claude and switch again."
        case .recoveryRequired: return "A previous Code account switch needs recovery. Quit every Claude instance before trying again."
        case .changed: return "The Code session folders changed unexpectedly. MacClaude stopped because it could not verify their identity."
        case .differentVolumes: return "Shared Code session folders and MacClaude must be on the same disk volume."
        case .conflictingWorktreePools: return "More than one account has its own Git worktree data. MacClaude has left both worktree pools untouched."
        }
    }
}

/// Moves one real Code history directory between account namespaces. The caller
/// must stop every Claude instance and its engines before activate or recover.
/// Account-owned scheduled-tasks.json files stay at their original namespaces.
public struct SharedSessionStore: Sendable {
    public let rootDirectory: URL
    private let faultInjector: (@Sendable (Checkpoint) throws -> Void)?
    private var verification: @Sendable () throws -> Void = {}
    private var manager: FileManager { .default }
    private static let maximumFileBytes = 64 * 1_024 * 1_024
    private static let maximumTreeBytes: Int64 = 512 * 1_024 * 1_024
    private static let schedule = "scheduled-tasks.json"
    private static let worktreePool = "git-worktrees.json"

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        faultInjector = nil
    }

    init(rootDirectory: URL, faultInjector: @escaping @Sendable (Checkpoint) throws -> Void) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.faultInjector = faultInjector
    }

    enum Checkpoint: String, CaseIterable, Sendable {
        case journalWritten, backupWritten, destinationParked, sourceScheduleParked
        case historyMoved, sourceRecreated, sourceScheduleRestored, destinationScheduleRestored, committed
        case destinationPoolParked, poolMoved, sourceEmptyPoolRestored
    }

    private var stateDirectory: URL { rootDirectory }
    private var journalURL: URL { stateDirectory.appendingPathComponent("journal.json") }
    private var receiptURL: URL { stateDirectory.appendingPathComponent("initial-backup.json") }
    private var activeURL: URL { stateDirectory.appendingPathComponent("active.json") }

    public func hasPendingTransaction() throws -> Bool {
        try validateStateRootIfPresent()
        return try kind(at: journalURL) != nil
    }

    public func inspect(profileDirectories: [URL]) throws -> SharedSessionInspection {
        if try hasPendingTransaction() { throw SharedSessionStoreError.recoveryRequired }
        let scan = try scanProfiles(profileDirectories)
        let master = try chooseMaster(scan.namespaces)
        return SharedSessionInspection(
            masterDirectory: master?.directory,
            activeProfileDirectory: master?.profile,
            uninitializedProfiles: scan.missing,
            canActivate: master != nil
        )
    }

    /// Reopening the recorded owner does not transfer data or require a new
    /// Claude version's transfer format to be approved. Fail closed if ownership
    /// changed or a transaction still needs recovery. This check never writes.
    public func canReopenWithoutTransfer(profileDirectories: [URL], destination: URL) throws -> Bool {
        guard try !hasPendingTransaction() else { return false }
        guard try kind(at: activeURL) != nil else {
            // No switch has been recorded yet. The only account with history is
            // still safe to reopen, because nothing would move.
            let scan = try scanProfiles(profileDirectories)
            let histories = scan.namespaces.filter { $0.hasHistory || $0.pool.hasData }
            return histories.count == 1 && histories[0].profile == destination.standardizedFileURL
        }
        let active: ActiveStore = try readJSON(ActiveStore.self, from: activeURL)
        guard active.version == 1 else { throw SharedSessionStoreError.changed }
        guard active.namespace.profile == destination.standardizedFileURL else { return false }
        let scan = try scanProfiles(profileDirectories)
        guard let owner = scan.namespaces.first(where: { $0.descriptor == active.namespace }),
              owner.identity == active.identity,
              try chooseMaster(scan.namespaces)?.descriptor == active.namespace else {
            throw SharedSessionStoreError.changed
        }
        return true
    }

    public func activate(profileDirectories: [URL], destination: URL,
                         verifyStopped: @escaping @Sendable () throws -> Void = {}) throws -> SharedSessionActivation {
        var worker = self
        worker.verification = verifyStopped
        return try worker.activateStopped(profileDirectories: profileDirectories, destination: destination)
    }

    private func activateStopped(profileDirectories: [URL], destination: URL) throws -> SharedSessionActivation {
        if try hasPendingTransaction() { throw SharedSessionStoreError.recoveryRequired }
        let scan = try scanProfiles(profileDirectories)
        let destination = destination.standardizedFileURL
        guard scan.profiles.contains(destination) else { throw SharedSessionStoreError.unsafe("the selected profile is not managed by MacClaude.") }
        guard let target = scan.namespaces.first(where: { $0.profile == destination }) else {
            return SharedSessionActivation(didMove: false, destinationNeedsSetup: true, backupDirectory: nil)
        }
        guard let source = try chooseMaster(scan.namespaces) else {
            return SharedSessionActivation(didMove: false, destinationNeedsSetup: true, backupDirectory: nil)
        }
        if source.directory == target.directory {
            if try kind(at: activeURL) == nil {
                try createPrivateDirectory(stateDirectory)
                try writeJSON(ActiveStore(version: 1, namespace: target.descriptor, identity: target.identity), to: activeURL)
            }
            return SharedSessionActivation(didMove: false, destinationNeedsSetup: false, backupDirectory: try existingBackup())
        }
        try createPrivateDirectory(stateDirectory)
        let stateIdentity = try requiredIdentity(stateDirectory, directory: true)
        guard source.identity.device == target.identity.device, source.identity.device == stateIdentity.device,
              source.pool.identity.map({ $0.device == stateIdentity.device }) ?? true,
              target.pool.identity.map({ $0.device == stateIdentity.device }) ?? true else {
            throw SharedSessionStoreError.differentVolumes
        }
        let existing = try readReceipt()
        let id = UUID().uuidString.lowercased()
        var journal = Journal(
            version: 1, id: id, namespaces: scan.namespaces.map(\.descriptor),
            source: source.descriptor, destination: target.descriptor,
            sourceIdentity: source.identity, destinationIdentity: target.identity,
            sourceSchedule: source.scheduleIdentity, destinationSchedule: target.scheduleIdentity,
            sourcePool: source.pool.identity, destinationPool: target.pool.identity,
            backupID: existing?.backupID ?? id, backupComplete: existing != nil,
            sourceReplacement: nil
        )
        try writeJSON(journal, to: journalURL)
        try checkpoint(.journalWritten)
        try finish(&journal)
        return SharedSessionActivation(didMove: true, destinationNeedsSetup: false, backupDirectory: backupDirectory(journal.backupID))
    }

    /// Complete an interrupted move. Safe to call repeatedly once Claude is stopped.
    @discardableResult
    public func recover(profileDirectories: [URL],
                        verifyStopped: @escaping @Sendable () throws -> Void = {}) throws -> Bool {
        var worker = self
        worker.verification = verifyStopped
        return try worker.recoverStopped(profileDirectories: profileDirectories)
    }

    private func recoverStopped(profileDirectories: [URL]) throws -> Bool {
        guard try hasPendingTransaction() else { return false }
        var journal: Journal = try readJSON(Journal.self, from: journalURL)
        try validateJournal(journal, allowedProfiles: profileDirectories)
        try verification()
        try finish(&journal)
        return true
    }

    private func finish(_ journal: inout Journal) throws {
        try validateJournal(journal, allowedProfiles: journal.namespaces.map(\.profile))
        try createPrivateDirectory(stateDirectory.appendingPathComponent("Transactions", isDirectory: true))
        let stage = transactionDirectory(journal.id)
        try createPrivateDirectory(stage)
        let parkedDestination = stage.appendingPathComponent("destination", isDirectory: true)
        let parkedSourceSchedule = stage.appendingPathComponent("source-schedule.json")
        let source = journal.source.directory
        let destination = journal.destination.directory

        if !journal.backupComplete {
            // No namespace has moved yet. Retrying a partial initial backup copies
            // the same bytes into private files, without touching the originals.
            guard try identity(source) == journal.sourceIdentity,
                  try identity(destination) == journal.destinationIdentity,
                  try identity(poolURL(journal.source.profile)) == journal.sourcePool,
                  try identity(poolURL(journal.destination.profile)) == journal.destinationPool else { throw SharedSessionStoreError.changed }
            try createPrivateDirectory(stateDirectory.appendingPathComponent("Backups", isDirectory: true))
            let backup = backupDirectory(journal.backupID)
            try createPrivateDirectory(backup)
            try verification()
            // The backup only writes private copies. Recheck running processes
            // once per batch, then again before every metadata or namespace move.
            var backupWriter = self
            backupWriter.verification = {}
            var poolFiles: [String?] = []
            for (index, descriptor) in journal.namespaces.enumerated() {
                let namespace = try inspectNamespace(descriptor)
                try backupWriter.copyPrivateTree(descriptor.directory, to: backup.appendingPathComponent(String(index), isDirectory: true))
                if namespace.pool.identity != nil {
                    let filename = "git-worktrees-\(index).json"
                    try backupWriter.copyPrivateTree(poolURL(descriptor.profile), to: backup.appendingPathComponent(filename))
                    poolFiles.append(filename)
                } else { poolFiles.append(nil) }
            }
            let inventory = try backupInventory(backup)
            try writeJSON(BackupManifest(version: 1, namespaces: journal.namespaces, worktreePoolFiles: poolFiles, files: inventory), to: backup.appendingPathComponent("namespaces.json"))
            try writeJSON(BackupReceipt(version: 1, backupID: journal.backupID), to: backup.appendingPathComponent("complete.json"))
            journal.backupComplete = true
            try writeJSON(journal, to: journalURL)
            try checkpoint(.backupWritten)
        }
        try verifyBackup(journal.backupID)
        if try readReceipt() == nil {
            try writeJSON(BackupReceipt(version: 1, backupID: journal.backupID), to: receiptURL)
        }

        if try identity(parkedDestination) == nil {
            do {
                let current = try inspectNamespace(journal.source)
                let target = try inspectNamespace(journal.destination)
                guard current.identity == journal.sourceIdentity, !target.hasHistory,
                      target.identity == journal.destinationIdentity,
                      target.scheduleIdentity == journal.destinationSchedule else { throw SharedSessionStoreError.changed }
            } catch {
                // Claude may have run between the interruption and this recovery.
                // With nothing renamed yet, dropping the journal restores a clean
                // state, and the next attempt reports the real conflict.
                if try nothingMoved(journal, stage: stage) { try unlinkFile(journalURL) }
                throw error
            }
        }
        try transferWorktreePool(journal, stage: stage)

        // Each operation recognizes its completed state by inode, so a crash
        // between a rename and the next journal write can be recovered safely.
        try move(journal.destinationIdentity, from: destination, to: parkedDestination)
        try checkpoint(.destinationParked)
        if let schedule = journal.sourceSchedule {
            try move(schedule, from: source.appendingPathComponent(Self.schedule), to: parkedSourceSchedule)
        }
        try checkpoint(.sourceScheduleParked)
        try move(journal.sourceIdentity, from: source, to: destination)
        try checkpoint(.historyMoved)

        if let replacement = journal.sourceReplacement {
            guard try identity(source) == replacement else { throw SharedSessionStoreError.changed }
        } else {
            if try kind(at: source) == nil { try createPrivateDirectory(source) }
            guard try requiredIdentity(source, directory: true) != journal.sourceIdentity,
                  try manager.contentsOfDirectory(atPath: source.path).isEmpty else { throw SharedSessionStoreError.changed }
            journal.sourceReplacement = try requiredIdentity(source, directory: true)
            try writeJSON(journal, to: journalURL)
        }
        try checkpoint(.sourceRecreated)
        if let schedule = journal.sourceSchedule {
            try move(schedule, from: parkedSourceSchedule, to: source.appendingPathComponent(Self.schedule))
        }
        try checkpoint(.sourceScheduleRestored)
        if let schedule = journal.destinationSchedule {
            try move(schedule, from: parkedDestination.appendingPathComponent(Self.schedule), to: destination.appendingPathComponent(Self.schedule))
        }
        try checkpoint(.destinationScheduleRestored)

        guard try identity(destination) == journal.sourceIdentity,
              try identity(source) == journal.sourceReplacement,
              try identity(source.appendingPathComponent(Self.schedule)) == journal.sourceSchedule,
              try identity(destination.appendingPathComponent(Self.schedule)) == journal.destinationSchedule,
              try identity(poolURL(journal.source.profile)) == journal.destinationPool,
              try identity(poolURL(journal.destination.profile)) == journal.sourcePool else {
            throw SharedSessionStoreError.changed
        }
        // Remember ownership even before the user creates the first session.
        try writeJSON(ActiveStore(version: 1, namespace: journal.destination, identity: journal.sourceIdentity), to: activeURL)
        // Both accounts have their own schedule and the exact same history
        // directory is at the destination. Remove only empty scaffolding; an
        // unexpected file appearing in staging is preserved for manual recovery.
        try unlinkFile(journalURL)
        try? removeEmptyDirectories(stage)
        try checkpoint(.committed)
    }

    private func scanProfiles(_ profiles: [URL]) throws -> Scan {
        let normalized = profiles.map(\.standardizedFileURL)
        guard normalized.allSatisfy(\.isFileURL),
              Set(normalized.map(\.path)).count == normalized.count, !normalized.isEmpty else {
            throw SharedSessionStoreError.unsafe("the profile list is empty or contains duplicates.")
        }
        var namespaces: [Namespace] = []
        var missing: [URL] = []
        var profileIdentities: [Identity] = []
        for profile in normalized {
            if let current = try identity(profile) {
                guard current.directory, !profileIdentities.contains(current) else {
                    throw SharedSessionStoreError.unsafe("the profile list contains the same directory more than once.")
                }
                profileIdentities.append(current)
            }
            guard let descriptor = try discover(profile) else { missing.append(profile); continue }
            namespaces.append(try inspectNamespace(descriptor))
        }
        return Scan(profiles: normalized, namespaces: namespaces, missing: missing)
    }

    private func discover(_ profile: URL) throws -> NamespaceDescriptor? {
        guard try kind(at: profile) != nil else { return nil }
        _ = try requiredIdentity(profile, directory: true)
        let tree = profile.appendingPathComponent("claude-code-sessions", isDirectory: true)
        guard try kind(at: tree) != nil else { return nil }
        _ = try requiredIdentity(tree, directory: true)
        let accountNames = try manager.contentsOfDirectory(atPath: tree.path).filter { $0 != "skills-plugin" && $0 != ".DS_Store" }
        guard accountNames.count <= 1 else { throw SharedSessionStoreError.ambiguousNamespace }
        guard let account = accountNames.first else { return nil }
        guard validID(account) else { throw SharedSessionStoreError.unsafe("an unexpected account folder was found.") }
        let accountDirectory = tree.appendingPathComponent(account, isDirectory: true)
        _ = try requiredIdentity(accountDirectory, directory: true)
        let organizations = try manager.contentsOfDirectory(atPath: accountDirectory.path).filter { $0 != ".DS_Store" }
        guard organizations.count <= 1 else { throw SharedSessionStoreError.ambiguousNamespace }
        guard let organization = organizations.first else { return nil }
        guard validID(organization) else { throw SharedSessionStoreError.unsafe("an unexpected organization folder was found.") }
        return NamespaceDescriptor(profile: profile, account: account, organization: organization)
    }

    private func inspectNamespace(_ descriptor: NamespaceDescriptor) throws -> Namespace {
        let directory = descriptor.directory
        let directoryIdentity = try requiredIdentity(directory, directory: true)
        let entries = try manager.contentsOfDirectory(atPath: directory.path)
        var hasHistory = false
        var total: Int64 = 0
        var count = 0
        for name in entries {
            let file = directory.appendingPathComponent(name)
            if name == Self.schedule {
                _ = try requiredIdentity(file, directory: false)
                try checkTreeBounds(file, bytes: &total, count: &count)
            } else if name == "imported-staging" {
                _ = try requiredIdentity(file, directory: true)
                guard try manager.contentsOfDirectory(atPath: file.path).isEmpty else { throw SharedSessionStoreError.pendingImport }
            } else if ["waiting-input", "backlog"].contains(name) {
                _ = try requiredIdentity(file, directory: true)
                let before = total
                try checkTreeBounds(file, bytes: &total, count: &count)
                hasHistory = hasHistory || total > before
            } else if name == "archived-sessions.idx" {
                _ = try requiredIdentity(file, directory: false)
                try checkTreeBounds(file, bytes: &total, count: &count)
                let data = try BoundedFile.read(file, maximumBytes: Self.maximumFileBytes)
                guard let archive = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let version = archive["v"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
                      let ids = archive["archived"] as? [String],
                      ids.allSatisfy({ $0.hasPrefix("local_") && $0.dropFirst(6).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) }) else {
                    throw SharedSessionStoreError.unsafe("the archived Code session index is not recognized.")
                }
                hasHistory = hasHistory || !ids.isEmpty
            } else if isTombstone(name) {
                _ = try requiredIdentity(file, directory: false)
                let before = total
                try checkTreeBounds(file, bytes: &total, count: &count)
                hasHistory = hasHistory || total > before
            } else if isSessionRecord(name) {
                _ = try requiredIdentity(file, directory: false)
                try checkTreeBounds(file, bytes: &total, count: &count)
                let data = try BoundedFile.read(file, maximumBytes: Self.maximumFileBytes)
                guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw SharedSessionStoreError.unsafe("a Code session record is not valid JSON.")
                }
                if let staged = record["stagedTranscriptPath"], !(staged is NSNull) { throw SharedSessionStoreError.pendingImport }
                hasHistory = true
            } else {
                throw SharedSessionStoreError.unsafe("an unsupported file was found in a Code session folder: \(name).")
            }
        }
        return Namespace(descriptor: descriptor, identity: directoryIdentity, hasHistory: hasHistory,
                         scheduleIdentity: try identity(directory.appendingPathComponent(Self.schedule)),
                         pool: try inspectPool(descriptor.profile))
    }

    private func chooseMaster(_ namespaces: [Namespace]) throws -> Namespace? {
        guard namespaces.filter({ $0.pool.hasData }).count <= 1 else { throw SharedSessionStoreError.conflictingWorktreePools }
        let histories = namespaces.filter { $0.hasHistory || $0.pool.hasData }
        guard histories.count <= 1 else { throw SharedSessionStoreError.multipleHistories }
        if let history = histories.first { return history }
        if try kind(at: activeURL) != nil {
            let active: ActiveStore = try readJSON(ActiveStore.self, from: activeURL)
            guard active.version == 1,
                  let selected = namespaces.first(where: { $0.descriptor == active.namespace }),
                  selected.identity == active.identity else { throw SharedSessionStoreError.changed }
            return selected
        }
        return namespaces.first
    }

    private func inspectPool(_ profile: URL) throws -> WorktreePool {
        let url = poolURL(profile)
        guard let fileIdentity = try identity(url) else { return WorktreePool(identity: nil, hasData: false) }
        guard !fileIdentity.directory else { throw SharedSessionStoreError.unsafe("the Git worktree pool is not a regular file.") }
        let data = try BoundedFile.read(url, maximumBytes: Self.maximumFileBytes)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["schemaVersion", "worktrees", "originUrls", "originPins", "pendingTombstones", "untrackedDirGc"]) else {
            throw SharedSessionStoreError.unsafe("the Git worktree pool format is not recognized.")
        }
        if let rawVersion = object["schemaVersion"] {
            guard let version = rawVersion as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 2 else {
                throw SharedSessionStoreError.unsafe("the Git worktree pool version is not supported.")
            }
        }
        var hasData = false
        for key in ["worktrees", "originUrls", "originPins"] {
            if let value = object[key] {
                guard let entries = value as? [String: Any] else { throw SharedSessionStoreError.unsafe("the Git worktree pool format is not recognized.") }
                hasData = hasData || !entries.isEmpty
            }
        }
        if let value = object["pendingTombstones"] {
            guard let entries = value as? [Any] else { throw SharedSessionStoreError.unsafe("the Git worktree pool format is not recognized.") }
            hasData = hasData || !entries.isEmpty
        }
        if let value = object["untrackedDirGc"] {
            guard let gc = value as? [String: Any], Set(gc.keys).isSubset(of: ["sightings", "roots", "cwds"]) else {
                throw SharedSessionStoreError.unsafe("the Git worktree cleanup format is not recognized.")
            }
            for (key, value) in gc {
                guard let entries = value as? [String: Any], entries.count <= 100_000 else { throw SharedSessionStoreError.unsafe("the Git worktree cleanup format is not recognized.") }
                if key == "cwds" {
                    // Claude records visited working directories even when no
                    // worktree exists. These integer timestamps do not claim a
                    // worktree; preserve this file as the destination's empty
                    // state when exchanging the real pool.
                    guard entries.allSatisfy({ path, raw in
                        guard !path.isEmpty, path.utf8.count <= 4_096, !path.contains("\0"),
                              let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return false }
                        let timestamp = value.doubleValue
                        return timestamp.isFinite && timestamp >= 0 && timestamp <= 9_007_199_254_740_991 && timestamp.rounded(.towardZero) == timestamp
                    }) else { throw SharedSessionStoreError.unsafe("the Git worktree cleanup timestamps are not recognized.") }
                } else {
                    hasData = hasData || !entries.isEmpty
                }
            }
        }
        return WorktreePool(identity: fileIdentity, hasData: hasData)
    }

    private func nothingMoved(_ journal: Journal, stage: URL) throws -> Bool {
        try identity(journal.source.directory) == journal.sourceIdentity
            && identity(journal.destination.directory) == journal.destinationIdentity
            && identity(poolURL(journal.source.profile)) == journal.sourcePool
            && identity(poolURL(journal.destination.profile)) == journal.destinationPool
            && identity(stage.appendingPathComponent("destination", isDirectory: true)) == nil
            && identity(stage.appendingPathComponent("destination-git-worktrees.json")) == nil
    }

    private func transferWorktreePool(_ journal: Journal, stage: URL) throws {
        let source = poolURL(journal.source.profile)
        let destination = poolURL(journal.destination.profile)
        let parked = stage.appendingPathComponent("destination-git-worktrees.json")
        // An entire exchange may already have completed before a crash. Unlike
        // account schedules, the original source pool travels with the history.
        let complete = try identity(source) == journal.destinationPool && identity(destination) == journal.sourcePool
        if !complete {
            if let expected = journal.destinationPool {
                if try identity(parked) == nil {
                    let pool = try inspectPool(journal.destination.profile)
                    guard !pool.hasData, pool.identity == expected else { throw SharedSessionStoreError.changed }
                }
                try move(expected, from: destination, to: parked)
            } else {
                let current = try identity(destination)
                guard current == nil || current == journal.sourcePool else { throw SharedSessionStoreError.changed }
            }
        }
        try checkpoint(.destinationPoolParked)
        if !complete, let expected = journal.sourcePool {
            try move(expected, from: source, to: destination)
        }
        try checkpoint(.poolMoved)
        if !complete, let expected = journal.destinationPool {
            try move(expected, from: parked, to: source)
        }
        try checkpoint(.sourceEmptyPoolRestored)
        guard try identity(source) == journal.destinationPool,
              try identity(destination) == journal.sourcePool else { throw SharedSessionStoreError.changed }
    }

    private func checkTreeBounds(_ url: URL, bytes: inout Int64, count: inout Int, depth: Int = 0) throws {
        count += 1
        guard depth <= 32, count <= 100_000 else { throw SharedSessionStoreError.unsafe("the Code session folder exceeds the safety bounds.") }
        guard let type = try kind(at: url) else { throw SharedSessionStoreError.changed }
        if type == .typeDirectory {
            for name in try manager.contentsOfDirectory(atPath: url.path) {
                try checkTreeBounds(url.appendingPathComponent(name), bytes: &bytes, count: &count, depth: depth + 1)
            }
        } else if type == .typeRegular {
            let attrs = try manager.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? Int64.max
            guard size <= Self.maximumFileBytes else { throw SharedSessionStoreError.unsafe("a Code session file is too large.") }
            bytes += size
            guard bytes <= Self.maximumTreeBytes, count <= 100_000 else { throw SharedSessionStoreError.unsafe("the Code session folder exceeds the safety bounds.") }
        } else {
            throw SharedSessionStoreError.unsafe("a session folder contains a symbolic link or special file.")
        }
    }

    private func copyPrivateTree(_ source: URL, to destination: URL) throws {
        let type = try kind(at: source)
        if type == .typeDirectory {
            try createPrivateDirectory(destination)
            for name in try manager.contentsOfDirectory(atPath: source.path) {
                try copyPrivateTree(source.appendingPathComponent(name), to: destination.appendingPathComponent(name))
            }
            try synchronizeDirectory(destination)
        } else if type == .typeRegular {
            let data = try BoundedFile.read(source, maximumBytes: Self.maximumFileBytes)
            try writePrivate(data, to: destination)
        } else { throw SharedSessionStoreError.changed }
    }

    private func validateJournal(_ journal: Journal, allowedProfiles: [URL]) throws {
        let allowed = Set(allowedProfiles.map { $0.standardizedFileURL.path })
        guard journal.version == 1, validID(journal.id), validID(journal.backupID),
              !journal.namespaces.isEmpty,
              Set(journal.namespaces.map { $0.profile.path }).count == journal.namespaces.count,
              journal.namespaces.contains(journal.source), journal.namespaces.contains(journal.destination),
              journal.source != journal.destination else { throw SharedSessionStoreError.unsafe("the recovery journal is invalid.") }
        for descriptor in journal.namespaces {
            guard allowed.contains(descriptor.profile.path), descriptor.profile.isFileURL,
                  descriptor.profile == descriptor.profile.standardizedFileURL,
                  validID(descriptor.account), validID(descriptor.organization) else {
                throw SharedSessionStoreError.unsafe("the recovery journal does not match the configured accounts.")
            }
            // The final leaf may temporarily be absent during recovery; its parents
            // must remain real directories in the exact originally authorized profile.
            for parent in [descriptor.profile, descriptor.directory.deletingLastPathComponent().deletingLastPathComponent(), descriptor.directory.deletingLastPathComponent()] {
                _ = try requiredIdentity(parent, directory: true)
            }
        }
        _ = try requiredIdentity(stateDirectory, directory: true)
    }

    private func move(_ expected: Identity, from source: URL, to destination: URL) throws {
        try verification()
        let sourceIdentity = try identity(source)
        let destinationIdentity = try identity(destination)
        if destinationIdentity == expected { return }
        guard sourceIdentity == expected, destinationIdentity == nil else { throw SharedSessionStoreError.changed }
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw posixError(source) }
        try synchronizeDirectory(source.deletingLastPathComponent())
        if source.deletingLastPathComponent() != destination.deletingLastPathComponent() {
            try synchronizeDirectory(destination.deletingLastPathComponent())
        }
    }

    private func createPrivateDirectory(_ directory: URL) throws {
        if let type = try kind(at: directory) {
            guard type == .typeDirectory else { throw SharedSessionStoreError.unsafe("a storage folder is a symbolic link or special file.") }
        } else {
            let parent = directory.deletingLastPathComponent()
            if try kind(at: parent) == nil { try createPrivateDirectory(parent) }
            _ = try requiredIdentity(parent, directory: true)
            try verification()
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try synchronizeDirectory(parent)
        }
    }

    private func identity(_ url: URL) throws -> Identity? {
        guard let type = try kind(at: url) else { return nil }
        guard type == .typeDirectory || type == .typeRegular else {
            throw SharedSessionStoreError.unsafe("a storage path is a symbolic link or special file.")
        }
        var status = stat()
        guard fstatat(AT_FDCWD, url.path, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError(url) }
        return Identity(device: UInt64(UInt32(bitPattern: status.st_dev)), inode: UInt64(status.st_ino), directory: type == .typeDirectory)
    }

    private func requiredIdentity(_ url: URL, directory: Bool) throws -> Identity {
        guard let value = try identity(url), value.directory == directory else { throw SharedSessionStoreError.changed }
        return value
    }

    private func kind(at url: URL) throws -> FileAttributeType? {
        do { return try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return nil }
    }

    private func writePrivate(_ data: Data, to destination: URL) throws {
        try verification()
        _ = try requiredIdentity(destination.deletingLastPathComponent(), directory: true)
        if let type = try kind(at: destination), type != .typeRegular { throw SharedSessionStoreError.changed }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".write-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError(temporary) }
        defer { close(descriptor); _ = unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw posixError(temporary) }
                offset += written
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, destination.path) == 0 else { throw posixError(destination) }
        try synchronizeDirectory(destination.deletingLastPathComponent())
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError(directory) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posixError(directory) }
    }

    private func unlinkFile(_ url: URL) throws {
        try verification()
        _ = try requiredIdentity(url, directory: false)
        guard unlink(url.path) == 0 else { throw posixError(url) }
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL, maximumBytes: Int = 1_048_576) throws -> T {
        do { return try JSONDecoder().decode(type, from: BoundedFile.read(url, maximumBytes: maximumBytes)) }
        catch { throw SharedSessionStoreError.unsafe("\(url.lastPathComponent) could not be read safely.") }
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writePrivate(encoder.encode(value), to: url)
    }

    private func readReceipt() throws -> BackupReceipt? {
        try validateStateRootIfPresent()
        guard try kind(at: receiptURL) != nil else { return nil }
        let receipt = try readJSON(BackupReceipt.self, from: receiptURL)
        guard receipt.version == 1, validID(receipt.backupID) else { throw SharedSessionStoreError.unsafe("the initial backup receipt is invalid.") }
        try verifyBackup(receipt.backupID)
        return receipt
    }

    private func verifyBackup(_ id: String) throws {
        _ = try requiredIdentity(stateDirectory.appendingPathComponent("Backups", isDirectory: true), directory: true)
        _ = try requiredIdentity(backupDirectory(id), directory: true)
        let complete = try readJSON(BackupReceipt.self, from: backupDirectory(id).appendingPathComponent("complete.json"))
        guard complete.version == 1, complete.backupID == id else { throw SharedSessionStoreError.unsafe("the initial backup is incomplete.") }
        let manifest = try readJSON(BackupManifest.self, from: backupDirectory(id).appendingPathComponent("namespaces.json"), maximumBytes: 32 * 1_024 * 1_024)
        guard manifest.version == 1, !manifest.namespaces.isEmpty,
              manifest.namespaces.allSatisfy({ $0.profile.isFileURL && validID($0.account) && validID($0.organization) }),
              manifest.worktreePoolFiles.count == manifest.namespaces.count,
              manifest.worktreePoolFiles.enumerated().allSatisfy({ $0.element == nil || $0.element == "git-worktrees-\($0.offset).json" }) else {
            throw SharedSessionStoreError.unsafe("the initial backup manifest is invalid.")
        }
        for index in manifest.namespaces.indices {
            _ = try requiredIdentity(backupDirectory(id).appendingPathComponent(String(index)), directory: true)
            if let filename = manifest.worktreePoolFiles[index] {
                _ = try requiredIdentity(backupDirectory(id).appendingPathComponent(filename), directory: false)
            }
        }
        guard try backupInventory(backupDirectory(id)) == manifest.files else {
            throw SharedSessionStoreError.unsafe("the initial backup files are missing or have changed. Restore the backup before switching accounts.")
        }
    }

    private func backupInventory(_ directory: URL) throws -> [BackupFile] {
        var result: [BackupFile] = []
        var total: Int64 = 0
        func visit(_ current: URL, prefix: String, depth: Int) throws {
            guard depth <= 32 else { throw SharedSessionStoreError.unsafe("the backup folder exceeds the safety bounds.") }
            _ = try requiredIdentity(current, directory: true)
            for name in try manager.contentsOfDirectory(atPath: current.path).sorted() {
                if prefix.isEmpty, ["complete.json", "namespaces.json"].contains(name) { continue }
                let file = current.appendingPathComponent(name)
                let relative = prefix + name
                let currentIdentity = try identity(file)
                guard let currentIdentity else { throw SharedSessionStoreError.changed }
                let size = currentIdentity.directory ? 0 : ((try manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? Int64.max)
                guard size <= Self.maximumFileBytes, result.count < 100_000 else { throw SharedSessionStoreError.unsafe("the backup folder exceeds the safety bounds.") }
                total += size
                guard total <= Self.maximumTreeBytes * 8 else { throw SharedSessionStoreError.unsafe("the backup folder exceeds the safety bounds.") }
                result.append(BackupFile(path: relative, directory: currentIdentity.directory, bytes: size))
                if currentIdentity.directory { try visit(file, prefix: relative + "/", depth: depth + 1) }
            }
        }
        try visit(directory, prefix: "", depth: 0)
        return result.sorted { $0.path < $1.path }
    }

    private func existingBackup() throws -> URL? { try readReceipt().map { backupDirectory($0.backupID) } }
    private func backupDirectory(_ id: String) -> URL { stateDirectory.appendingPathComponent("Backups/\(id)", isDirectory: true) }
    private func transactionDirectory(_ id: String) -> URL { stateDirectory.appendingPathComponent("Transactions/\(id)", isDirectory: true) }
    private func poolURL(_ profile: URL) -> URL { profile.appendingPathComponent(Self.worktreePool) }
    private func checkpoint(_ point: Checkpoint) throws { try faultInjector?(point) }
    private func validID(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value.lowercased() }
    private func isSessionRecord(_ name: String) -> Bool {
        guard name.hasPrefix("local_") else { return false }
        let suffix = name.hasSuffix(".json.tmp") ? ".json.tmp" : ".json"
        return name.hasSuffix(suffix) && validID(String(name.dropFirst(6).dropLast(suffix.count)))
    }
    private func isTombstone(_ name: String) -> Bool {
        guard name.hasPrefix("deleted_") else { return false }
        let stem = String(name.dropFirst(8))
        return validID(stem.hasPrefix("local_") ? String(stem.dropFirst(6)) : stem)
    }
    private func posixError(_ url: URL) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path]) }

    private func validateStateRootIfPresent() throws {
        if try kind(at: stateDirectory) != nil { _ = try requiredIdentity(stateDirectory, directory: true) }
    }

    private func removeEmptyDirectories(_ directory: URL, depth: Int = 0) throws {
        guard depth <= 32, try kind(at: directory) == .typeDirectory else { return }
        for name in try manager.contentsOfDirectory(atPath: directory.path) {
            try removeEmptyDirectories(directory.appendingPathComponent(name), depth: depth + 1)
        }
        guard try manager.contentsOfDirectory(atPath: directory.path).isEmpty else { return }
        try verification()
        guard rmdir(directory.path) == 0 else { throw posixError(directory) }
        try synchronizeDirectory(directory.deletingLastPathComponent())
    }

    private struct Identity: Codable, Equatable { let device: UInt64; let inode: UInt64; let directory: Bool }
    private struct NamespaceDescriptor: Codable, Equatable {
        let profile: URL
        let account: String
        let organization: String
        var directory: URL { profile.appendingPathComponent("claude-code-sessions/\(account)/\(organization)", isDirectory: true) }
    }
    private struct Namespace {
        let descriptor: NamespaceDescriptor
        let identity: Identity
        let hasHistory: Bool
        let scheduleIdentity: Identity?
        let pool: WorktreePool
        var profile: URL { descriptor.profile }
        var directory: URL { descriptor.directory }
    }
    private struct Scan { let profiles: [URL]; let namespaces: [Namespace]; let missing: [URL] }
    private struct BackupReceipt: Codable { let version: Int; let backupID: String }
    private struct BackupManifest: Codable { let version: Int; let namespaces: [NamespaceDescriptor]; let worktreePoolFiles: [String?]; let files: [BackupFile] }
    private struct BackupFile: Codable, Equatable { let path: String; let directory: Bool; let bytes: Int64 }
    private struct WorktreePool { let identity: Identity?; let hasData: Bool }
    private struct ActiveStore: Codable { let version: Int; let namespace: NamespaceDescriptor; let identity: Identity }
    private struct Journal: Codable {
        let version: Int
        let id: String
        let namespaces: [NamespaceDescriptor]
        let source: NamespaceDescriptor
        let destination: NamespaceDescriptor
        let sourceIdentity: Identity
        let destinationIdentity: Identity
        let sourceSchedule: Identity?
        let destinationSchedule: Identity?
        let sourcePool: Identity?
        let destinationPool: Identity?
        let backupID: String
        var backupComplete: Bool
        var sourceReplacement: Identity?
    }
}
