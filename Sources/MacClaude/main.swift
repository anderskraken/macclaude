import AppKit
import MacClaudeCore

let arguments = CommandLine.arguments
let home = FileManager.default.homeDirectoryForCurrentUser
let root = home.appendingPathComponent("Library/Application Support/MacClaude", isDirectory: true)

if arguments.contains("--diagnostics") {
    let paths = ProfilePaths(rootDirectory: root, homeDirectory: home)
    do {
        let configuration = try ProfileStore(rootDirectory: root).load()
        let installation = ClaudeInstallation.find(savedPath: configuration.claudeApplicationPath)
        let instances = ClaudeRuntime().instances()
        let runningIDs = Set(configuration.profiles.filter { profile in
            instances.contains { $0.profile.matches(profile: profile, paths: paths) }
        }.map(\.id))
        let unidentified = instances.filter { instance in
            !configuration.profiles.contains { instance.profile.matches(profile: $0, paths: paths) }
        }.count
        let location = SessionLocation.read(root: root.appendingPathComponent("SharedSessions"),
                                            profiles: configuration.profiles, paths: paths)
        print(DiagnosticsReport(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            claudeVersion: installation?.version, profiles: configuration.profiles,
            runningIDs: runningIDs, unidentifiedProcesses: unidentified, location: location,
            transfersSupported: installation?.version == AppDelegate.checkedClaudeVersion, phase: nil,
            pendingID: nil, launchTimedOut: false, lastFailure: nil).text)

    } catch {
        FileHandle.standardError.write(Data("Diagnostics unavailable: \(DiagnosticsReport.failureCode(error))\n".utf8))
        exit(1)
    }
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate(root: root)
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
