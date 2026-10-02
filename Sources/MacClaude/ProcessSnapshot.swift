import Darwin
import Foundation

struct ProcessIdentity: Hashable {
    let pid: pid_t
    let parent: pid_t
    let startedSeconds: Int
    let startedMicroseconds: Int
    let name: String
    let userID: uid_t

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pid == rhs.pid && lhs.startedSeconds == rhs.startedSeconds && lhs.startedMicroseconds == rhs.startedMicroseconds
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(startedSeconds)
        hasher.combine(startedMicroseconds)
    }
}

struct ProcessSnapshot {
    let processes: Set<ProcessIdentity>

    static func read() throws -> Self {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { throw RuntimeError.processInspectionFailed }
            let stride = MemoryLayout<kinfo_proc>.stride
            let capacity = size / stride + 64
            guard capacity < 1_000_000 else { throw RuntimeError.processInspectionFailed }
            let buffer = UnsafeMutablePointer<kinfo_proc>.allocate(capacity: capacity)
            defer { buffer.deallocate() }
            size = capacity * stride
            if sysctl(&mib, 3, buffer, &size, nil, 0) != 0 {
                if errno == ENOMEM { continue }
                throw RuntimeError.processInspectionFailed
            }
            guard size % stride == 0 else { throw RuntimeError.processInspectionFailed }
            let processes = Set(UnsafeBufferPointer(start: buffer, count: size / stride).compactMap { item -> ProcessIdentity? in
                // A zombie has exited and cannot hold session files open.
                guard item.kp_proc.p_pid > 0, item.kp_proc.p_stat != SZOMB else { return nil }
                var command = item.kp_proc.p_comm
                let name = withUnsafeBytes(of: &command) { bytes in
                    String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
                }
                return ProcessIdentity(pid: item.kp_proc.p_pid, parent: item.kp_eproc.e_ppid,
                                       startedSeconds: Int(item.kp_proc.p_starttime.tv_sec),
                                       startedMicroseconds: Int(item.kp_proc.p_starttime.tv_usec),
                                       name: name, userID: item.kp_eproc.e_ucred.cr_uid)
            })
            return Self(processes: processes)
        }
        throw RuntimeError.processInspectionFailed
    }

    /// An ancestry-independent guard for orphaned Desktop engines and helpers.
    /// Call immediately before each shared-store mutation. This supplements the
    /// shutdown wait and session ownership registry; it does not lock out an
    /// independently launched application between filesystem operations.
    static func verifyClaudeStopped(installationURL: URL) throws {
        let snapshot = try read()
        var writers = Set<ProcessIdentity>()
        var unreadable = Set<ProcessIdentity>()
        for process in snapshot.processes where process.userID == getuid() {
            if let path = executablePath(pid: process.pid) {
                if isClaudeExecutable(path: path, installationURL: installationURL) {
                    writers.insert(process)
                }
            } else if isClaudeProcessName(process.name) {
                unreadable.insert(process)
            }
        }
        guard !writers.isEmpty || !unreadable.isEmpty else { return }
        // The process may have exited, or its PID may have been reused, while
        // querying its path. Never confuse that with a surviving writer.
        let live = try read().processes
        if !writers.isDisjoint(with: live) { throw RuntimeError.processesStillRunning }
        if !unreadable.isDisjoint(with: live) { throw RuntimeError.processInspectionFailed }
    }

    static func executablePath(pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro not imported by Swift.
        var bytes = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = bytes.withUnsafeMutableBytes { buffer in
            proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        guard length > 0 else { return nil }
        return String(decoding: bytes.prefix(Int(length)).prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    static func isCrashReporter(_ process: ProcessIdentity) -> Bool {
        guard let path = executablePath(pid: process.pid) else { return false }
        return URL(fileURLWithPath: path).lastPathComponent == "chrome_crashpad_handler"
    }

    static func isClaudeExecutable(path: String, installationURL: URL) -> Bool {
        let executable = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        // Crashpad can legitimately outlive its app and does not write Code's
        // session store. Other Claude helpers, including renderers, must stop.
        guard executable.lastPathComponent != "chrome_crashpad_handler" else { return false }
        let installation = installationURL.standardizedFileURL.resolvingSymlinksInPath()
        if executable.path.hasPrefix(installation.path + "/Contents/") { return true }

        // Desktop downloads its native engine under each profile's userData
        // directory. This exact suffix also covers custom MacClaude profiles,
        // while excluding ordinary ~/.local/share/claude/versions CLI installs.
        let components = executable.pathComponents
        if components.count >= 6,
           components[components.count - 6] == "claude-code",
           Array(components.suffix(4)) == ["claude.app", "Contents", "MacOS", "claude"] {
            return true
        }

        // Also catch orphaned helpers from another Claude installation or an
        // App Translocation path. Inspect bundle metadata, never process args.
        guard isClaudeProcessName(executable.lastPathComponent) else { return false }
        var ancestor = executable.deletingLastPathComponent()
        while ancestor.path != "/" {
            if ancestor.pathExtension == "app",
               Bundle(url: ancestor)?.bundleIdentifier == ClaudeInstallation.bundleIdentifier {
                return true
            }
            ancestor.deleteLastPathComponent()
        }
        return false
    }

    private static func isClaudeProcessName(_ name: String) -> Bool {
        let name = name.lowercased()
        return name == "claude" || name == "claude-code" || name.hasPrefix("claude helper")
    }

    /// Returns current metadata for the exact observed process identities.
    /// Reparenting preserves identity; PID reuse does not.
    func survivors(of tracked: Set<ProcessIdentity>) -> Set<ProcessIdentity> {
        Set(processes.filter { tracked.contains($0) })
    }

    func descendants(of roots: Set<pid_t>) -> Set<ProcessIdentity> {
        var parents = roots
        var result = Set<ProcessIdentity>()
        while true {
            let children = processes.filter { parents.contains($0.parent) && !result.contains($0) && !roots.contains($0.pid) }
            guard !children.isEmpty else { return result }
            result.formUnion(children)
            parents.formUnion(children.map(\.pid))
        }
    }
}
