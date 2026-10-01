import AppKit
import ServiceManagement
import MacClaudeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let root: URL
    private let store: ProfileStore
    private let paths: ProfilePaths
    private let runtime = ClaudeRuntime()
    private var configuration = AppConfiguration()
    private var installation: ClaudeInstallation?
    private var lock: InstanceLock?
    private var statusItem: NSStatusItem!
    private var windowController: AccountsWindowController!
    private var notice: String?
    private var lastFailure: DiagnosticFailure?
    private var busyID: String?
    private var sessionLocation: SessionLocation = .checking
    private var inspectionGeneration = 0
    private var usage: [String: LocalUsageSnapshot] = [:]
    private var rows: [AccountRowState] = []
    private var terminateWhenIdle = false
    private var availability: AccountAvailability {
        AccountAvailability(claudeVersion: installation?.version, location: sessionLocation, profiles: configuration.profiles)
    }
    private var transfersSupported: Bool { availability.transfersSupported }

    private var observers: [NSObjectProtocol] = []
    private var sharedRoot: URL { root.appendingPathComponent("SharedSessions", isDirectory: true) }

    init(root: URL) {
        self.root = root
        self.store = ProfileStore(rootDirectory: root)
        self.paths = ProfilePaths(rootDirectory: root, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            lock = try InstanceLock(root: root)
        } catch InstanceLockError.alreadyRunning {
            if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "io.github.agensdev.macclaude")
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
                other.activate(options: [.activateAllWindows])
            }
            NSApp.terminate(nil)
            return
        } catch {
            present(error, title: "MacClaude couldn’t open its storage", closeTitle: "Quit")
            NSApp.terminate(nil)
            return
        }
        do {
            configuration = try store.load()
        } catch {
            let alert = NSAlert()
            alert.messageText = "MacClaude couldn’t read its accounts"
            alert.informativeText = "\(error.localizedDescription)\n\nYour saved configuration has been left untouched."
            alert.addButton(withTitle: "Show Folder & Quit")
            alert.addButton(withTitle: "Quit")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(root) }
            NSApp.terminate(nil)
            return
        }
        installation = ClaudeInstallation.find(savedPath: configuration.claudeApplicationPath)
        installMainMenu()
        windowController = AccountsWindowController { [weak self] action in self?.handle(action) }
        runtime.onStateChange = { [weak self] in self?.refresh() }
        runtime.onLateLaunchCompletion = { [weak self] id, error in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshSessionLocation()
                if let error, let profile = self.configuration.profiles.first(where: { $0.id == id }) {
                    self.presentOpeningError(error, profile: profile, startingOwnerID: nil)
                }
                self.refresh()
            }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "person.crop.rectangle.stack", accessibilityDescription: "MacClaude accounts")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "MacClaude — Account Switcher"
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == ClaudeInstallation.bundleIdentifier else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // An update replaces the bundle while Claude is closed.
                    self.installation = ClaudeInstallation.find(savedPath: self.configuration.claudeApplicationPath)
                    self.refresh()
                    if name == NSWorkspace.didTerminateApplicationNotification, self.busyID == nil {
                        await self.refreshSessionLocation()
                    }
                }
            })
        }
        reloadUsage()
        refresh()
        // Login launches remain unobtrusive; a normal launch always presents Accounts.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !launchedAtLogin { windowController.show() }
        Task { await refreshSessionLocation() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if windowController != nil { showAccounts() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard busyID != nil || runtime.isLaunching else { return .terminateNow }
        // Quitting mid-switch would abandon the transfer; finish first, then quit.
        terminateWhenIdle = true
        notice = "MacClaude will quit when this switch finishes."
        refresh()
        return .terminateLater
    }

    func menuWillOpen(_ menu: NSMenu) { reloadUsage(); refresh(); rebuildMenu(menu) }

    private func reloadUsage() {
        usage = Dictionary(uniqueKeysWithValues: configuration.profiles.compactMap { profile in
            LocalUsageReader.read(from: paths.userDataDirectory(for: profile)).map { (profile.id, $0) }
        })
    }

    private func refresh() {
        if terminateWhenIdle, busyID == nil, !runtime.isLaunching {
            terminateWhenIdle = false
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        let availability = availability
        let instances = runtime.instances()
        rows = configuration.profiles.map { profile in
            let snapshot = usage[profile.id]
            return AccountRowState(id: profile.id, name: profile.name, isDefault: profile.isDefault,
                                   isRunning: instances.contains { $0.profile.matches(profile: profile, paths: paths) },
                                   isBusy: (busyID ?? runtime.pendingProfileID) == profile.id, usageText: snapshot.map { UsagePresentation($0).text },
                                   holdsSessions: sessionLocation.ownerID == profile.id,
                                   canOpen: availability.canOpen(profile), blockedReason: availability.blockedReason,
                                   usageIsStale: snapshot?.isStale() ?? false)
        }
        let banner = availability.banner
        let message = progressText ?? notice ?? banner.text
        let action = progressText == nil && notice == nil ? banner.action : nil
        windowController?.render(AccountsViewState(accounts: rows, claudePath: installation?.url.path,
                                                   claudeVersion: installation?.version, notice: message, isBusy: busyID != nil || runtime.isLaunching,
                                                   noticeAction: action, canAdd: transfersSupported))
    }

    private func refreshSessionLocation() async {
        inspectionGeneration += 1
        let generation = inspectionGeneration
        let profiles = configuration.profiles
        let paths = paths
        let sharedRoot = sharedRoot
        let location = await Task.detached(priority: .utility) {
            SessionLocation.read(root: sharedRoot, profiles: profiles, paths: paths)
        }.value
        guard generation == inspectionGeneration else { return }
        sessionLocation = location
        refresh()
    }

    private var progressText: String? {
        guard let id = busyID ?? runtime.pendingProfileID else { return nil }
        let name = configuration.profiles.first { $0.id == id }?.name ?? "Claude"
        let text = (runtime.phase ?? .checkingSessions).title(account: name)
        return runtime.launchHasTimedOut
            ? text + " macOS is taking longer than expected. Check for a Claude window or permission prompt."
            : text
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for (index, row) in rows.enumerated() {
            let item = NSMenuItem(title: row.isBusy ? "\(row.name) (\((runtime.phase ?? .checkingSessions).title(account: row.name)))" : row.name,
                                  action: #selector(openMenuAccount(_:)), keyEquivalent: index < 9 ? String(index + 1) : "")
            item.target = self
            item.representedObject = row.id
            item.isEnabled = busyID == nil && !runtime.isLaunching && row.canOpen
            item.state = row.isRunning ? .on : .off
            item.toolTip = row.holdsSessions
                ? "Open \(row.name). Your sessions are already here."
                : (row.blockedReason ?? "Restart Claude with this account and the shared Code sessions.")
            menu.addItem(item)
            if let snapshot = usage[row.id] {
                let usage = UsagePresentation(snapshot)
                for line in [usage.amounts, usage.recorded] {
                    let detail = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                    detail.isEnabled = false
                    detail.indentationLevel = 1
                    detail.attributedTitle = NSAttributedString(string: line, attributes: [
                        .font: NSFont.menuFont(ofSize: 11),
                        .foregroundColor: usage.isStale ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor
                    ])
                    menu.addItem(detail)
                }
            }
        }
        menu.addItem(.separator())
        addMenuItem(menu, "Add Account…", #selector(addAccount), "n", enabled: busyID == nil && !runtime.isLaunching && transfersSupported)
        addMenuItem(menu, "Manage Accounts…", #selector(showAccounts), ",")
        menu.addItem(.separator())
        let login = addMenuItem(menu, "Launch at Login", #selector(toggleLogin), "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.isEnabled = Bundle.main.bundleURL.pathExtension == "app"
        addMenuItem(menu, "About MacClaude", #selector(showAbout), "")
        menu.addItem(.separator())
        addMenuItem(menu, "Quit MacClaude", #selector(quit), "q")
    }

    @discardableResult private func addMenuItem(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        addMenuItem(appMenu, "About MacClaude", #selector(showAbout), "")
        appMenu.addItem(.separator())
        addMenuItem(appMenu, "Manage Accounts…", #selector(showAccounts), ",")
        addMenuItem(appMenu, "Quit MacClaude", #selector(quit), "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    private func handle(_ action: AccountsAction) {
        switch action {
        case .open(let id): openAccount(id)
        case .add: addAccount()
        case .rename(let id): renameAccount(id)
        case .remove(let id): removeAccount(id)
        case .revealProfile(let id):
            guard let profile = configuration.profiles.first(where: { $0.id == id }) else { return }
            reveal(paths.userDataDirectory(for: profile))
        case .revealSharedFolder: revealShared()
        case .chooseClaude: chooseClaude()
        case .refresh:
            notice = nil
            reloadUsage()
            Task { await refreshSessionLocation() }
        case .revealProfiles: revealProfileFolders()
        case .revealRecovery: reveal(sharedRoot)
        case .help: showHelp()
        case .copyDiagnostics: copyDiagnostics()
        }
    }

    @objc private func openMenuAccount(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { openAccount(id) }
    }

    private func openAccount(_ id: String) {
        guard busyID == nil, !runtime.isLaunching, let profile = configuration.profiles.first(where: { $0.id == id }) else { return }
        guard let installation else { chooseClaude(); return }
        busyID = id
        inspectionGeneration += 1
        notice = nil
        refresh()
        Task { @MainActor in
            var startingOwnerID: String?
            do {
                let directories = configuration.profiles.map { paths.userDataDirectory(for: $0) }
                let target = paths.userDataDirectory(for: profile)
                let sharedRoot = sharedRoot
                let profiles = configuration.profiles
                let profilePaths = paths
                let initial = await Task.detached {
                    SessionLocation.read(root: sharedRoot, profiles: profiles, paths: profilePaths)
                }.value
                startingOwnerID = initial.ownerID
                sessionLocation = initial
                if case let .unavailable(error) = initial { throw error }
                let reuse = initial.ownerID == profile.id
                if installation.version != AccountAvailability.checkedClaudeVersion {
                    let canReopen = try await Task.detached {
                        try SharedSessionStore(rootDirectory: sharedRoot)
                            .canReopenWithoutTransfer(profileDirectories: directories, destination: target)
                    }.value
                    guard canReopen else { throw SharedCompatibilityError(version: installation.version) }
                }
                try await runtime.open(profile, profiles: configuration.profiles, paths: paths,
                                       installation: installation, reuseRunning: reuse) {
                    let codeConfig = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
                    let installationURL = installation.url
                    if installation.version != AccountAvailability.checkedClaudeVersion {
                        // After a reboot/update, reopen the existing owner without
                        // calling either recovery or activation. Recheck ownership
                        // after shutdown; an earlier inspection is not authority to move.
                        let canReopen = try await Task.detached {
                            try ProcessSnapshot.verifyClaudeStopped(installationURL: installationURL)
                            try SessionWriterGuard.check(profileDirectories: directories, configDirectory: codeConfig,
                                                         liveProcessIDs: Set(try ProcessSnapshot.read().processes.map(\.pid)))
                            return try SharedSessionStore(rootDirectory: sharedRoot)
                                .canReopenWithoutTransfer(profileDirectories: directories, destination: target)
                        }.value
                        guard canReopen else { throw SharedCompatibilityError(version: installation.version) }
                        return
                    }
                    let activation = try await Task.detached {
                        let shared = SharedSessionStore(rootDirectory: sharedRoot)
                        // Every rename rechecks that Claude is stopped. The transcript
                        // writer scan reads every session record, so it runs once per phase.
                        let verify: @Sendable () throws -> Void = {
                            let currentVersion = try ClaudeInstallation(url: installationURL).version
                            guard currentVersion == AccountAvailability.checkedClaudeVersion else {
                                throw SharedCompatibilityError(version: currentVersion)
                            }
                            try ProcessSnapshot.verifyClaudeStopped(installationURL: installationURL)
                        }
                        let verifyNoWriters: @Sendable () throws -> Void = {
                            try verify()
                            try SessionWriterGuard.check(profileDirectories: directories, configDirectory: codeConfig,
                                                         liveProcessIDs: Set(try ProcessSnapshot.read().processes.map(\.pid)))
                        }
                        try verifyNoWriters()
                        if try shared.recover(profileDirectories: directories, verifyStopped: verify) { try verifyNoWriters() }
                        return try shared.activate(profileDirectories: directories, destination: target, verifyStopped: verify)
                    }.value
                    self.notice = activation.destinationNeedsSetup
                        ? "Sign in to \(profile.name) and open Code, then choose it here again to load your shared sessions."
                        : nil
                }
                if configuration.lastOpenedProfileID != id {
                    var next = configuration
                    next.lastOpenedProfileID = id
                    do {
                        try store.save(next)
                        configuration = next
                    } catch { present(error, title: "Claude opened, but MacClaude couldn’t save its preference") }
                }
            } catch {
                await refreshSessionLocation()
                presentOpeningError(error, profile: profile, startingOwnerID: startingOwnerID)
                busyID = nil
                reloadUsage()
                refresh()
                return
            }
            await refreshSessionLocation()
            busyID = nil
            reloadUsage()
            refresh()
        }
    }

    @objc private func addAccount() {
        guard busyID == nil, !runtime.isLaunching, transfersSupported else { return }
        guard let name = askName(title: "Add Account", message: "Claude will quit and open a new sign-in window. Sign in, open Code, then choose this account here again.", value: "", button: "Add & Open") else { return }
        do {
            let profile = AccountProfile(id: UUID().uuidString.lowercased(), name: name, createdAt: Date())
            var next = configuration
            next.profiles.append(profile)
            try store.save(next)
            configuration = next
            refresh()
            openAccount(profile.id)
        } catch { present(error, title: "Couldn’t add account") }
    }

    private func renameAccount(_ id: String) {
        guard busyID == nil, let index = configuration.profiles.firstIndex(where: { $0.id == id }) else { return }
        guard let name = askName(title: "Rename Account", message: "Only the name in MacClaude changes.", value: configuration.profiles[index].name, button: "Save") else { return }
        do {
            var next = configuration
            next.profiles[index].name = name
            try store.save(next)
            configuration = next
            refresh()
        } catch { present(error, title: "Couldn’t rename account") }
    }

    private func removeAccount(_ id: String) {
        guard busyID == nil, let profile = configuration.profiles.first(where: { $0.id == id }), !profile.isDefault else { return }
        guard !runtime.instances().contains(where: { $0.profile.matches(profile: profile, paths: paths) }) else {
            notice = "Quit \(profile.name) in Claude before removing it from MacClaude."
            refresh()
            return
        }
        // A closed profile may still own the one real session store. Keep it
        // reachable until another profile has taken ownership.
        guard case .ready = sessionLocation, sessionLocation.ownerID != profile.id else {
            notice = sessionLocation.ownerID == profile.id
                ? "Switch to another account before removing \(profile.name). It has your sessions."
                : "MacClaude can’t confirm where your sessions are, so it won’t remove an account yet."
            refresh()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Remove \(profile.name) from MacClaude?"
        alert.informativeText = "Its sign-in and files stay on this Mac."
        alert.addButton(withTitle: "Remove from List")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            var next = configuration
            next.profiles.removeAll { $0.id == id }
            if next.lastOpenedProfileID == id { next.lastOpenedProfileID = nil }
            try store.save(next)
            configuration = next
            refresh()
        } catch { present(error, title: "Couldn’t remove account") }
    }

    private func askName(title: String, message: String, value: String, button: String) -> String? {
        AccountNameDialog(title: title, message: message, value: value, button: button).run()
    }

    private func chooseClaude() {
        let panel = NSOpenPanel()
        panel.title = "Choose Claude"
        panel.message = "Select the Claude desktop app installed on this Mac."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let selected = try ClaudeInstallation(url: url)
            var next = configuration
            next.claudeApplicationPath = selected.url.path
            try store.save(next)
            configuration = next
            installation = selected
            notice = nil
            refresh()
        } catch {
            present(error, title: "Couldn’t use this application",
                    action: ("Choose Claude App…", { [weak self] in self?.chooseClaude() }))
        }
    }

    @objc private func showAccounts() {
        reloadUsage(); refresh(); windowController.show()
        if busyID == nil { Task { await refreshSessionLocation() } }
    }
    private func revealProfileFolders() {
        let folders = configuration.profiles.map { paths.userDataDirectory(for: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting(folders)
    }
    @objc private func revealShared() { reveal(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) }
    private func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path) }
        else { notice = "This folder will appear after Claude first uses it: \(url.path)"; refresh(); windowController.show() }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { present(error, title: "Couldn’t change Launch at Login") }
    }

    @objc private func copyDiagnostics() {
        Task { @MainActor in
            // During a transfer, use the last settled snapshot and report the stage;
            // an inspection half way through a rename would be misleading.
            if busyID == nil && !runtime.isLaunching { await refreshSessionLocation() }
            let report = DiagnosticsReport(
                claudeVersion: installation?.version, profiles: configuration.profiles, instances: runtime.instances(), paths: paths,
                location: busyID != nil || runtime.isLaunching ? .checking : sessionLocation,
                phase: runtime.phase ?? (busyID == nil ? nil : .checkingSessions),
                pendingID: runtime.pendingProfileID, launchTimedOut: runtime.launchHasTimedOut, lastFailure: lastFailure)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report.text, forType: .string)
            notice = "Diagnostics copied. They contain no names, paths or conversations."
            refresh()
            NSAccessibility.post(element: windowController.window ?? NSApp as Any,
                                 notification: .announcementRequested,
                                 userInfo: [.announcement: "Diagnostics copied", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "How MacClaude works"
        alert.informativeText = "Each account keeps its own Claude login. Switching quits Claude, moves your Code sessions to the chosen account, and opens Claude again. Only one account runs at a time.\n\nAlways switch here. Opening another account directly starts a separate history that MacClaude won’t merge."
        alert.addButton(withTitle: "Done")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "MacClaude",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            .credits: NSAttributedString(string: "Not affiliated with Anthropic.")
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentOpeningError(_ error: Error, profile: AccountProfile, startingOwnerID: String?) {
        if case RuntimeError.launchTimedOut = error {
            lastFailure = DiagnosticFailure(error)
            // LaunchServices cannot cancel its request. Keep progress in the window;
            // the runtime's completion callback clears it when the request resolves.
            notice = nil
            windowController.show()
            return
        }
        if error is SharedCompatibilityError, sessionLocation.canReopen,
           startingOwnerID == sessionLocation.ownerID {
            lastFailure = DiagnosticFailure(error)
            notice = nil
            windowController.show()
            return
        }
        let outcome = sessionLocation.outcome(startingOwnerID: startingOwnerID, profiles: configuration.profiles)
        var action = storageAction(for: error)
        if action == nil, case .recoveryRequired = sessionLocation {
            action = storageAction(for: SharedSessionStoreError.recoveryRequired)
        } else if action == nil, let running = runtime.instances().first(where: { $0.profile != .unknown })?.application {
            // Focus only an existing process. This action never launches or switches.
            action = ("Show Claude", { running.unhide(); running.activate(options: [.activateAllWindows]) })
        }
        present(error, title: "Couldn’t open \(profile.name)", detail: outcome, action: action)
    }

    private func present(_ error: Error, title: String, detail: String = "",
                         action: (String, () -> Void)? = nil, closeTitle: String = "Close") {
        lastFailure = DiagnosticFailure(error)
        let action = action ?? storageAction(for: error)
        let message = [error.localizedDescription, detail].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let action { alert.addButton(withTitle: action.0) }
        alert.addButton(withTitle: closeTitle)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn { action?.1() }
    }

    private func storageAction(for error: Error) -> (String, () -> Void)? {
        guard let error = error as? SharedSessionStoreError else { return nil }
        switch error {
        case .multipleHistories, .conflictingWorktreePools, .ambiguousNamespace:
            return ("Show Profile Folders", { [weak self] in self?.revealProfileFolders() })
        case .recoveryRequired:
            return ("Show Recovery Folder", { [weak self] in
                guard let self else { return }
                self.reveal(self.sharedRoot)
            })
        default: return nil
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

struct SharedCompatibilityError: LocalizedError {
    let version: String
    var errorDescription: String? {
        "Switching isn’t available on Claude \(version) yet. MacClaude has been tested with Claude \(AccountAvailability.checkedClaudeVersion)."
    }
}
