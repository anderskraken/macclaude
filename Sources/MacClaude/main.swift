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
        let location = SessionLocation.read(root: root.appendingPathComponent("SharedSessions"),
                                            profiles: configuration.profiles, paths: paths)
        print(DiagnosticsReport(claudeVersion: installation?.version, profiles: configuration.profiles,
                                instances: ClaudeRuntime().instances(), paths: paths, location: location,
                                phase: nil, pendingID: nil, launchTimedOut: false, lastFailure: nil).text)

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
