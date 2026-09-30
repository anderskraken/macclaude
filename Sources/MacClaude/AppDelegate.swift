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
    nonisolated static let checkedClaudeVersion = "2.9939.4"
    private var transfersSupported: Bool { installation?.version == Self.checkedClaudeVersion }
    private var sessionOwner: AccountProfile? { configuration.profiles.first { $0.id == sessionLocation.ownerID } }

    private var observers: [NSObjectProtocol] = []

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
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == ClaudeInstallation.bundleIdentifier else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.refresh()
                    if name == NSWorkspace.didTerminateApplicationNotification, self.busyID == nil {
                        await self.refreshSessionLocation()
                    }
                }
            })
        }
        refresh()
        // Login launches remain unobtrusive; a normal launch always presents Accounts.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !launchedAtLogin { windowController.show() }
        Task { await refreshSessionLocation() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController?.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        busyID == nil && !runtime.isLaunching ? .terminateNow : .terminateCancel
    }

    func menuWillOpen(_ menu: NSMenu) { refresh(); rebuildMenu(menu) }

    private func refresh() {
        installation = ClaudeInstallation.find(savedPath: configuration.claudeApplicationPath)
        let instances = runtime.instances()
        let rows = configuration.profiles.map { profile in
            let snapshot = LocalUsageReader.read(from: paths.userDataDirectory(for: profile))
            return AccountRowState(id: profile.id, name: profile.name, isDefault: profile.isDefault,
                                   isRunning: instances.contains { $0.profile.matches(profile: profile, paths: paths) },
                                   isBusy: (busyID ?? runtime.pendingProfileID) == profile.id, usageText: snapshot.map { UsagePresentation($0).text },
                                   holdsSessions: sessionLocation.ownerID == profile.id,
                                   canOpen: canOpen(profile), blockedReason: blockedReason,
                                   usageIsStale: snapshot?.isStale() ?? false)
        }
        let banner = statusBanner
        let message = progressText ?? notice ?? banner.text
        let action = progressText == nil && notice == nil ? banner.action : nil
        windowController?.render(AccountsViewState(accounts: rows, claudePath: installation?.url.path,
                                                   claudeVersion: installation?.version, notice: message, isBusy: busyID != nil || runtime.isLaunching,
                                                   noticeAction: action, canAdd: transfersSupported))
    }

    private var blockedReason: String? {
        installation == nil ? "Choose the Claude app first." :
            (!transfersSupported ? "Account switching is paused until this Claude version is checked." : nil)
    }

    private func canOpen(_ profile: AccountProfile) -> Bool {
        guard installation != nil else { return false }
        if transfersSupported { return true }
        return sessionLocation.ownerID == profile.id && sessionLocation.canReopen
    }

    private var statusBanner: (text: String?, action: AccountNoticeAction?) {
        guard let installation else {
            return ("Claude wasn’t found. Choose the installed Claude app.", .init(title: "Choose Claude App…", action: .chooseClaude))
        }
        switch sessionLocation {
        case .checking: return ("Checking where your shared sessions are…", nil)
        case .recoveryRequired:
            return ("A session transfer needs recovery. Keep Claude closed until recovery completes." +
                    (transfersSupported ? " Select an account to retry recovery." : " Recovery is paused until this Claude version is checked."),
                    .init(title: "Show Recovery Folder", action: .revealRecovery))
        case let .unavailable(error):
            return ("Couldn’t verify your session location. " + error.localizedDescription, .init(title: "Show Profile Folders", action: .revealProfiles))
        case .ready:
            guard let owner = sessionOwner else {
                return (transfersSupported ? nil : "Claude \(installation.version) hasn’t been checked for account switching. No shared session owner has been recorded yet.", nil)
            }
            if !transfersSupported {
                let detail = sessionLocation.canReopen
                    ? "Open \(owner.name) to continue without moving sessions."
                    : "MacClaude needs to verify the recorded session directory before reopening it."
                let action: AccountNoticeAction? = sessionLocation.canReopen
                    ? .init(title: "Open \(owner.name)", action: .open(owner.id)) : nil
                return ("Your sessions are in \(owner.name).\nClaude \(installation.version) hasn’t been checked for account switching. \(detail)", action)
            }
            return ("Your shared sessions are in \(owner.name).", nil)
        }
    }

    private func refreshSessionLocation() async {
        inspectionGeneration += 1
        let generation = inspectionGeneration
        let profiles = configuration.profiles
        let paths = paths
        let sharedRoot = root.appendingPathComponent("SharedSessions")
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
        let title = NSMenuItem(title: "MacClaude", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let instances = runtime.instances()
        for (index, profile) in configuration.profiles.enumerated() {
            let item = NSMenuItem(title: (busyID ?? runtime.pendingProfileID) == profile.id ? (progressText ?? profile.name) : profile.name,
                                  action: #selector(openMenuAccount(_:)), keyEquivalent: index < 9 ? String(index + 1) : "")
            item.target = self
            item.representedObject = profile.id
            item.isEnabled = busyID == nil && !runtime.isLaunching && canOpen(profile)
            item.state = instances.contains { $0.profile.matches(profile: profile, paths: paths) } ? .on : .off
            item.toolTip = sessionLocation.ownerID == profile.id
                ? "Open \(profile.name). Your sessions are already here."
                : (blockedReason ?? "Restart Claude with this account and the shared Code sessions.")
            menu.addItem(item)
            if let snapshot = LocalUsageReader.read(from: paths.userDataDirectory(for: profile)) {
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
        addMenuItem(menu, "Open Shared Code Files", #selector(revealShared), "")
        menu.addItem(.separator())
        let login = addMenuItem(menu, "Launch at Login", #selector(toggleLogin), "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.isEnabled = Bundle.main.bundleURL.pathExtension == "app"
        addMenuItem(menu, "Copy Diagnostics", #selector(copyDiagnostics), "")
        addMenuItem(menu, "How MacClaude Works", #selector(showHelp), "")
        addMenuItem(menu, "About MacClaude", #selector(showAbout), "")
        menu.addItem(.separator())
        addMenuItem(menu, "Quit MacClaude", #selector(quit), "q", enabled: busyID == nil && !runtime.isLaunching)
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
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = edit
        main.addItem(editItem)
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
            Task { await refreshSessionLocation() }
        case .revealProfiles: revealProfileFolders()
        case .revealRecovery: reveal(root.appendingPathComponent("SharedSessions"))
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
                let sharedRoot = root.appendingPathComponent("SharedSessions", isDirectory: true)
                let profiles = configuration.profiles
                let profilePaths = paths
                let initial = await Task.detached {
                    SessionLocation.read(root: sharedRoot, profiles: profiles, paths: profilePaths)
                }.value
                startingOwnerID = initial.ownerID
                sessionLocation = initial
                if case let .unavailable(error) = initial { throw error }
                let reuse = initial.ownerID == profile.id
                if installation.version != Self.checkedClaudeVersion {
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
                    if installation.version != Self.checkedClaudeVersion {
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
                        let verify: @Sendable () throws -> Void = {
                            let currentVersion = try ClaudeInstallation(url: installationURL).version
                            guard currentVersion == Self.checkedClaudeVersion else {
                                throw SharedCompatibilityError(version: currentVersion)
                            }
                            try ProcessSnapshot.verifyClaudeStopped(installationURL: installationURL)
                            try SessionWriterGuard.check(profileDirectories: directories, configDirectory: codeConfig,
                                                         liveProcessIDs: Set(try ProcessSnapshot.read().processes.map(\.pid)))
                        }
                        try verify()
                        _ = try shared.recover(profileDirectories: directories, verifyStopped: verify)
                        return try shared.activate(profileDirectories: directories, destination: target, verifyStopped: verify)
                    }.value
                    self.notice = activation.destinationNeedsSetup
                        ? "Sign in to \(profile.name) and open Code, then choose it here again to load your shared sessions."
                        : nil
                }
                if installation.version != Self.checkedClaudeVersion { self.notice = nil }
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
            }
            await refreshSessionLocation()
            busyID = nil
            refresh()
        }
    }

    @objc private func addAccount() {
        guard busyID == nil, !runtime.isLaunching, transfersSupported else { return }
        guard let name = askName(title: "Add Account", message: "Name this account, then sign in once in Claude. Adding it quits the current Claude account. Sign in and open Code, then choose the new account here again to load your shared sessions.", value: "", button: "Add & Open") else { return }
        do {
            let name = try ProfileStore.validatedName(name)
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
        guard let name = askName(title: "Rename Account", message: "This changes the name in MacClaude. Your Claude sign-in and files stay in place.", value: configuration.profiles[index].name, button: "Save") else { return }
        do {
            var next = configuration
            next.profiles[index].name = try ProfileStore.validatedName(name)
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
        do {
            let shared = SharedSessionStore(rootDirectory: root.appendingPathComponent("SharedSessions"))
            guard try !shared.hasPendingTransaction() else { throw SharedSessionStoreError.recoveryRequired }
            let inspection = try shared.inspect(profileDirectories: configuration.profiles.map { paths.userDataDirectory(for: $0) })
            guard inspection.activeProfileDirectory != paths.userDataDirectory(for: profile) else {
                notice = "Switch to another account before removing \(profile.name); it currently holds your shared sessions."
                refresh()
                return
            }
        } catch { present(error, title: "Couldn’t check shared sessions"); return }
        let alert = NSAlert()
        alert.messageText = "Remove \(profile.name) from MacClaude?"
        alert.informativeText = "Its sign-in and files will remain on this Mac. Only the entry in this account list is removed."
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
        refresh(); windowController.show()
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
            let instances = runtime.instances()
            let runningIDs = Set(configuration.profiles.filter { profile in
                instances.contains { $0.profile.matches(profile: profile, paths: paths) }
            }.map(\.id))
            let unidentified = instances.filter { instance in
                !configuration.profiles.contains { instance.profile.matches(profile: $0, paths: paths) }
            }.count
            let report = DiagnosticsReport(
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                claudeVersion: installation?.version, profiles: configuration.profiles,
                runningIDs: runningIDs, unidentifiedProcesses: unidentified,
                location: busyID != nil || runtime.isLaunching ? .checking : sessionLocation,
                transfersSupported: transfersSupported, phase: runtime.phase ?? (busyID == nil ? nil : .checkingSessions),
                pendingID: runtime.pendingProfileID, launchTimedOut: runtime.launchHasTimedOut, lastFailure: lastFailure)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report.text, forType: .string)
            NSAccessibility.post(element: windowController.window ?? NSApp as Any,
                                 notification: .announcementRequested,
                                 userInfo: [.announcement: "Diagnostics copied", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    @objc private func showHelp() {
        let alert = NSAlert()
        let originalName = configuration.profiles.first(where: \.isDefault)?.name ?? "Personal"
        alert.messageText = "One workspace, several accounts"
        alert.informativeText = "\(originalName) uses your existing Claude sign-in. Each added account keeps its own login. Choose an account here or in the menu bar.\n\nSwitching gracefully quits Claude, moves the same Code session folder to the selected account, and reopens Claude. One account runs at a time. Finish running work before switching; MacClaude never force-quits Claude.\n\nYour Code session history, project files, local skills, instructions, and memory stay shared. There is no import or background synchronization. Account schedules stay with their original login. Cloud chats, Chat memory, and Cowork stay with each account.\n\nA private backup is saved before the first move. If a move is interrupted, the next switch completes recovery before opening Claude. Always switch through MacClaude; starting another account directly can create a separate history.\n\nTransfers support Claude 2.9939.4. After an update, you can reopen the account holding your sessions. Transferring them to another account requires a compatibility check. MacClaude never reads your passwords or authentication tokens."
        alert.addButton(withTitle: "Done")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "MacClaude",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            .credits: NSAttributedString(string: "Account Switcher\nA small native companion for Claude on Mac.\n\nIndependent software. Not affiliated with Anthropic.")
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentOpeningError(_ error: Error, profile: AccountProfile, startingOwnerID: String?) {
        lastFailure = DiagnosticFailure(error)
        if case RuntimeError.launchTimedOut = error {
            // LaunchServices cannot cancel its request. Keep progress in the window;
            // the runtime's completion callback clears it when the request resolves.
            notice = nil
            windowController.show()
            return
        }
        if error is SharedCompatibilityError, sessionLocation.canReopen,
           startingOwnerID == sessionLocation.ownerID {
            notice = nil
            windowController.show()
            return
        }
        let outcome = sessionLocation.outcome(startingOwnerID: startingOwnerID, profiles: configuration.profiles)
        var action: (String, () -> Void)?
        if case SharedSessionStoreError.multipleHistories = error {
            action = ("Show Profile Folders", { [weak self] in self?.revealProfileFolders() })
        } else if case SharedSessionStoreError.conflictingWorktreePools = error {
            action = ("Show Profile Folders", { [weak self] in self?.revealProfileFolders() })
        } else if case .recoveryRequired = sessionLocation {
            action = ("Show Recovery Folder", { [weak self] in
                guard let self else { return }
                self.reveal(self.root.appendingPathComponent("SharedSessions"))
            })
        } else if let running = runtime.instances().first(where: { $0.profile != .unknown })?.application {
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
        notice = message
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
                self.reveal(self.root.appendingPathComponent("SharedSessions"))
            })
        default: return nil
        }
    }

    @objc private func quit() { if busyID == nil && !runtime.isLaunching { NSApp.terminate(nil) } }
}

struct SharedCompatibilityError: LocalizedError {
    let version: String
    var errorDescription: String? {
        "Claude \(version) needs a compatibility check before MacClaude can move your session folder. Transfers have been checked with Claude 2.9939.4."
    }
}
