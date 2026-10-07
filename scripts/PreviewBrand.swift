import AppKit

/// An isolated visual harness: never opens ProfileStore or touches Claude.
@main
struct PreviewBrand {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        app.mainMenu = menu
        let state = AccountsViewState(accounts: [
            AccountRowState(id: "preview-personal", name: "Personal", isDefault: true,
                            isRunning: true, isBusy: false, usageText: "5h: 24% used · Week: 38% used\nRecorded 2 min ago",
                            holdsSessions: true, canOpen: true, blockedReason: nil),
            AccountRowState(id: "preview-work", name: "Work", isDefault: false,
                            isRunning: false, isBusy: false, usageText: "5h: 8% used · Week: 12% used\nRecorded 7 min ago",
                            holdsSessions: false, canOpen: true, blockedReason: nil)
        ], claudePath: "/Applications/Claude.app", claudeVersion: "2.9939.4",
           notice: "Your shared sessions are in Personal.", isBusy: false, noticeAction: nil, canAdd: true)
        var controllers: [AccountsWindowController] = []
        for (index, appearance) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let controller = AccountsWindowController { _ in }
            let window = controller.window!
            window.setFrameAutosaveName("")
            window.title = "MacClaude Brand Preview — \(index == 0 ? "Light" : "Dark · Minimum size")"
            window.appearance = NSAppearance(named: appearance)
            if index == 1 { window.setFrame(NSRect(x: 740, y: 200, width: 520, height: 480), display: false) }
            else { window.setFrameOrigin(NSPoint(x: 60, y: 200)) }
            controller.render(state)
            controller.show()
            controllers.append(controller)
        }
        withExtendedLifetime(controllers) { app.run() }
    }
}
