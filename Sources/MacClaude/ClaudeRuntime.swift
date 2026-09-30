import AppKit
import Darwin
import MacClaudeCore

struct ClaudeInstallation {
    static let bundleIdentifier = "com.anthropic.claudefordesktop"
    let url: URL
    let version: String

    init(url: URL) throws {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == Self.bundleIdentifier,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.contains("/"),
              FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/\(executable)").path)
        else { throw RuntimeError.invalidApplication }
        self.url = url
        version = info["CFBundleShortVersionString"] as? String ?? "Unknown version"
    }

    @MainActor static func find(savedPath: String?) -> ClaudeInstallation? {
        // An explicitly selected installation must not silently fall back to another one.
        if let savedPath { return try? ClaudeInstallation(url: URL(fileURLWithPath: savedPath)) }
        let candidates = [URL(fileURLWithPath: "/Applications/Claude.app"),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Claude.app"),
                          NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)]
        return candidates.compactMap { $0 }.compactMap { try? ClaudeInstallation(url: $0) }.first
    }
}

enum RuntimeError: LocalizedError {
    case invalidApplication, applicationChanged, unreadableInstances, launchDidNotMatch, launchTimedOut, unsafeDirectory, alreadyLaunching
    case quitRefused, processesStillRunning, processInspectionFailed
    case shutdownTimedOut(survivors: [String], additionalCount: Int)
    var errorDescription: String? {
        switch self {
        case .invalidApplication: return "Choose the installed Claude desktop application. This app does not appear to be Claude."
        case .applicationChanged: return "Claude updated during the switch. MacClaude left it closed to protect your sessions. Its new version needs a compatibility check before switching again."
        case .unreadableInstances: return "A running Claude instance could not be identified. Quit that instance in Claude, then try again. MacClaude will not risk opening the same profile twice."
        case .launchDidNotMatch: return "Claude opened, but its account profile could not be verified. MacClaude has left it running. Check its window before trying again."
        case .launchTimedOut: return "macOS is still opening Claude. Check for a Claude window or approval prompt. Further launches remain paused until macOS finishes this request."
        case .unsafeDirectory: return "This account’s profile folder is a symbolic link or is not a directory. Restore the original folder before opening it."
        case .alreadyLaunching: return "Another account is opening. Wait for it to finish."
        case .quitRefused: return "Claude hasn’t quit. Finish any running work and respond to its quit dialog, then switch again. Your session folders have not been moved."
        case .processesStillRunning: return "Claude or one of its session processes is still running. Finish quitting Claude, then switch again. MacClaude stopped the switch to protect your sessions."
        case .processInspectionFailed: return "MacClaude couldn’t verify that Claude’s session processes have stopped. MacClaude stopped the switch to protect your sessions."
        case let .shutdownTimedOut(survivors, additionalCount):
            var details: [String] = []
            if !survivors.isEmpty {
                let more = additionalCount > 0 ? " and \(additionalCount) more" : ""
                details.append("Processes still present: \(survivors.joined(separator: ", "))\(more).")
            }
            return "Claude hasn’t fully stopped after 20 seconds. Let it finish shutting down, then try switching again. The switch stopped to protect your sessions.\n\n" + details.joined(separator: "\n")
        }
    }
}

struct ClaudeInstance {
    let application: NSRunningApplication
    let profile: InstanceProfile
}

enum SwitchPhase: String, Sendable {
    case checkingSessions = "checking_sessions"
    case closing = "closing_claude"
    case preparing = "preparing_sessions"
    case opening = "opening_claude"
    case verifying = "checking_account"

    func title(account: String) -> String {
        switch self {
        case .checkingSessions: return "Checking shared sessions…"
        case .closing: return "Closing Claude…"
        case .preparing: return "Preparing shared sessions…"
        case .opening: return "Opening \(account)…"
        case .verifying: return "Checking \(account)’s account…"
        }
    }
}

@MainActor
final class ClaudeRuntime {
    private var operationActive = false
    private var outstandingProcesses = Set<ProcessIdentity>()
    private(set) var pendingProfileID: String?
    var onStateChange: (() -> Void)?
    var onLateLaunchCompletion: ((String, Error?) -> Void)?
    private(set) var launchHasTimedOut = false
    private(set) var phase: SwitchPhase? { didSet { onStateChange?() } }
    var isLaunching: Bool { operationActive || pendingProfileID != nil }

    func instances() -> [ClaudeInstance] {
        NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeInstallation.bundleIdentifier)
            .filter { !$0.isTerminated }
            .map { ClaudeInstance(application: $0, profile: .classify(arguments: ProcessArguments.read(pid: $0.processIdentifier))) }
    }

    func open(_ profile: AccountProfile, profiles: [AccountProfile], paths: ProfilePaths,
              installation: ClaudeInstallation, reuseRunning: Bool,
              prepare: @escaping @MainActor () async throws -> Void) async throws {
        guard !isLaunching else { throw RuntimeError.alreadyLaunching }
        operationActive = true
        defer {
            operationActive = false
            if pendingProfileID == nil { phase = nil }
        }
        launchHasTimedOut = false
        phase = .verifying
        let running = instances()
        guard running.allSatisfy({ instance in profiles.contains { instance.profile.matches(profile: $0, paths: paths) } }) else {
            throw RuntimeError.unreadableInstances
        }
        if reuseRunning, running.count == 1,
           let existing = running.first(where: { $0.profile.matches(profile: profile, paths: paths) }) {
            if !existing.application.isTerminated,
               existing.application.bundleIdentifier == ClaudeInstallation.bundleIdentifier {
                // A running Electron app may have no open windows. Reopen is
                // addressed to this exact PID rather than an ambiguous bundle ID.
                let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                                                  eventID: AEEventID(kAEReopenApplication),
                                                  targetDescriptor: NSAppleEventDescriptor(processIdentifier: existing.application.processIdentifier),
                                                  returnID: AEReturnID(kAutoGenerateReturnID),
                                                  transactionID: AETransactionID(kAnyTransactionID))
                // Reopen is best effort: a transient AppleEvent failure should
                // not prevent activation or the exited-process fallback below.
                _ = try? event.sendEvent(options: [.noReply, .neverInteract], timeout: 1)
                existing.application.unhide()
                if existing.application.activate(options: [.activateAllWindows]) { return }
            }
            // A process can exit between discovery and activation; inspect again below.
        }
        phase = .closing
        try await stopInstances(running)
        guard instances().isEmpty else { throw RuntimeError.processesStillRunning }
        try ProcessSnapshot.verifyClaudeStopped(installationURL: installation.url)
        phase = .preparing
        try await prepare()
        // A manually launched instance must not race the transfer and launch.
        guard instances().isEmpty else { throw RuntimeError.processesStillRunning }
        try ProcessSnapshot.verifyClaudeStopped(installationURL: installation.url)
        if !profile.isDefault {
            let directory = paths.userDataDirectory(for: profile)
            try Self.prepareProfileDirectory(directory)
        }
        // Claude can install an update while quitting. Never launch a newly
        // replaced version against the just-transferred session store.
        guard try ClaudeInstallation(url: installation.url).version == installation.version else {
            throw RuntimeError.applicationChanged
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = paths.launchArguments(for: profile)
        // No Claude environment variables: Desktop handles its own authentication,
        // and Claude Code keeps the user's normal shared configuration directory.
        pendingProfileID = profile.id
        phase = .opening
        let _: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            let gate = LaunchCompletion(continuation: continuation)
            // A plan change can reset Claude's remembered surface to Chat. Deliver
            // the Code landing link with this exact launch/profile; no prompt
            // or session import is attached to it.
            NSWorkspace.shared.open([URL(string: "claude://code/new")!],
                                    withApplicationAt: installation.url,
                                    configuration: configuration) { application, error in
                Task { @MainActor in
                    // Keep the profile reserved through identity verification, even
                    // after the caller's watchdog has stopped waiting.
                    let result: Result<NSRunningApplication, Error>
                    if let error { result = .failure(error) }
                    else if let application {
                        self.phase = .verifying
                        do {
                            try await self.verify(application, profile: profile, paths: paths)
                            result = .success(application)
                        } catch { result = .failure(error) }
                    } else { result = .failure(RuntimeError.launchDidNotMatch) }
                    self.pendingProfileID = nil
                    self.launchHasTimedOut = false
                    let delivered = gate.finish(result)
                    if !self.operationActive { self.phase = nil }
                    if !delivered {
                        switch result {
                        case .success: self.onLateLaunchCompletion?(profile.id, nil)
                        case let .failure(error): self.onLateLaunchCompletion?(profile.id, error)
                        }
                    }
                    self.onStateChange?()
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                if gate.finish(.failure(RuntimeError.launchTimedOut)) {
                    self.launchHasTimedOut = true
                    self.onStateChange?()
                }
            }
        }
    }

    private func verify(_ opened: NSRunningApplication, profile: AccountProfile, paths: ProfilePaths) async throws {
        // LaunchServices may report completion before argv is queryable.
        for _ in 0..<20 {
            let identity = InstanceProfile.classify(arguments: ProcessArguments.read(pid: opened.processIdentifier))
            if !opened.isTerminated, opened.bundleIdentifier == ClaudeInstallation.bundleIdentifier,
               identity.matches(profile: profile, paths: paths) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RuntimeError.launchDidNotMatch
    }

    private func stopInstances(_ running: [ClaudeInstance]) async throws {
        var tracked = outstandingProcesses
        defer { outstandingProcesses = tracked }
        var parents = Set(running.map { $0.application.processIdentifier })
        let initial = try ProcessSnapshot.read()
        tracked.formUnion(initial.descendants(of: parents))
        tracked.formUnion(initial.processes.filter { parents.contains($0.pid) })
        for instance in running {
            guard instance.application.isTerminated || instance.application.terminate() else { throw RuntimeError.quitRefused }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        repeat {
            let snapshot = try ProcessSnapshot.read()
            // Remember children created during normal shutdown, even if they later
            // become orphaned. PID + start time avoids mistaking a reused PID.
            parents = Set(tracked.filter { snapshot.processes.contains($0) }.map(\.pid))
            tracked.formUnion(snapshot.descendants(of: parents))
            tracked = Set(tracked.filter { !ProcessSnapshot.isCrashReporter($0) })
            // Retained NSRunningApplication objects can report isTerminated ==
            // false after the process and every child have exited. Kernel
            // PID/start-time identities are the shutdown authority; fresh app
            // enumeration and the independent writer guard run before transfer.
            if snapshot.survivors(of: tracked).isEmpty {
                tracked.removeAll()
                return
            }
            try await Task.sleep(for: .milliseconds(150))
        } while ContinuousClock.now < deadline
        // Capture bounded, useful diagnostics without reading arguments or
        // session content. Recheck once at the deadline to avoid reporting a
        // process that exited during the final sleep.
        let finalSnapshot = try ProcessSnapshot.read()
        let survivors = finalSnapshot.survivors(of: tracked).sorted { $0.pid < $1.pid }
        if survivors.isEmpty {
            tracked.removeAll()
            return
        }
        let limit = 6
        let descriptions = survivors.prefix(limit).map { process in
            let name = process.name.components(separatedBy: .controlCharacters).joined()
            return "\(name.isEmpty ? "process" : name) (PID \(process.pid))"
        }
        throw RuntimeError.shutdownTimedOut(survivors: descriptions,
                                            additionalCount: max(0, survivors.count - limit))
    }

    private static func prepareProfileDirectory(_ directory: URL) throws {
        let fm = FileManager.default
        // Never follow an unexpected link when creating an identity store.
        for candidate in [directory.deletingLastPathComponent(), directory] {
            if let attributes = try? fm.attributesOfItem(atPath: candidate.path) {
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw RuntimeError.unsafeDirectory }
            } else {
                try fm.createDirectory(at: candidate, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        }
    }
}

@MainActor final class LaunchCompletion {
    var continuation: CheckedContinuation<NSRunningApplication, Error>?
    init(continuation: CheckedContinuation<NSRunningApplication, Error>) { self.continuation = continuation }
    @discardableResult func finish(_ result: Result<NSRunningApplication, Error>) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(with: result)
        return true
    }
}

enum ProcessArguments {
    static func read(pid: pid_t) -> [String]? {
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.size
        var sizeMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&sizeMIB, 2, &argmax, &argmaxSize, nil, 0) == 0,
              argmax > 0, argmax <= 8 * 1024 * 1024 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let result = buffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard result == 0, size > MemoryLayout<Int32>.size else { return nil }
        return ProcessArgumentBuffer.decode(Data(buffer.prefix(size)))
    }
}

final class InstanceLock {
    private let descriptor: Int32
    init(root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try fm.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw RuntimeError.unsafeDirectory
        }
        let file = root.appendingPathComponent("instance.lock").path
        descriptor = Darwin.open(file, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { throw InstanceLockError.alreadyRunning }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }
    deinit { close(descriptor) }
}

enum InstanceLockError: Error { case alreadyRunning }
