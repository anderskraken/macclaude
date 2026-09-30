import AppKit

struct AccountRowState: Sendable {
    let id: String
    let name: String
    let isDefault: Bool
    let isRunning: Bool
    let isBusy: Bool
    let usageText: String?
    let holdsSessions: Bool
    let canOpen: Bool
    let blockedReason: String?
    var usageIsStale: Bool = false
}

struct AccountsViewState: Sendable {
    let accounts: [AccountRowState]
    let claudePath: String?
    let claudeVersion: String?
    let notice: String?
    let isBusy: Bool
    let noticeAction: AccountNoticeAction?
    let canAdd: Bool
}

struct AccountNoticeAction: Sendable {
    let title: String
    let action: AccountsAction
}

enum AccountsAction: Sendable {
    case open(String)
    case add
    case rename(String)
    case remove(String)
    case revealProfile(String)
    case revealSharedFolder
    case chooseClaude
    case refresh
    case help
    case revealProfiles
    case revealRecovery
    case copyDiagnostics
}

@MainActor
final class AccountsWindowController: NSWindowController {
    private let onAction: (AccountsAction) -> Void
    private let rows = NSStackView()
    private let applicationLabel = NSTextField(labelWithString: "")
    private let noticeLabel = NSTextField(wrappingLabelWithString: "")
    private let noticeContainer = NSStackView()
    private let noticeButton = ActionButton(title: "")
    private let addButton = ActionButton(title: "Add Account…", symbol: "plus")
    private let sharedButton = ActionButton(title: "Shared Files", symbol: "folder")
    private let settingsButton = MenuButton(symbol: "ellipsis.circle", accessibilityLabel: "More options")

    init(onAction: @escaping (AccountsAction) -> Void) {
        self.onAction = onAction
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacClaude — Account Switcher"
        window.subtitle = "Your accounts. One workspace."
        window.minSize = NSSize(width: 520, height: 480)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MacClaudeAccountsWindow")
        window.center()
        super.init(window: window)
        buildInterface(in: window)
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func render(_ state: AccountsViewState) {
        for view in rows.arrangedSubviews {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, account) in state.accounts.enumerated() {
            let row = AccountCard(account: account, index: index, isBusy: state.isBusy, onAction: onAction)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        if state.accounts.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "Add an account to get started. You’ll sign in securely inside Claude.")
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            empty.font = .systemFont(ofSize: 13)
            rows.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        if let path = state.claudePath {
            applicationLabel.stringValue = state.claudeVersion.map { "Claude \($0)" } ?? "Claude is ready"
            applicationLabel.toolTip = path
        } else {
            applicationLabel.stringValue = "Choose Claude to get started"
            applicationLabel.toolTip = "Use More options to choose the Claude desktop app."
        }
        noticeLabel.stringValue = state.notice ?? ""
        noticeContainer.isHidden = state.notice?.isEmpty != false
        noticeButton.isHidden = state.noticeAction == nil
        noticeButton.title = state.noticeAction?.title ?? ""
        noticeButton.toolTip = state.noticeAction?.title
        noticeButton.isEnabled = !state.isBusy
        noticeButton.handler = { [weak self] in
            if let action = state.noticeAction { self?.onAction(action.action) }
        }
        addButton.isEnabled = !state.isBusy && state.canAdd
        addButton.toolTip = state.canAdd ? "Add an account (⌘N)" : "Adding accounts is paused until this Claude version is checked."
        sharedButton.isEnabled = !state.isBusy
        settingsButton.isEnabled = !state.isBusy
        if let window { window.recalculateKeyViewLoop() }
    }

    private func buildInterface(in window: NSWindow) {
        let content = WindowBackgroundView()
        window.contentView = content

        let heading = NSTextField(labelWithString: "Accounts")
        heading.font = .systemFont(ofSize: 27, weight: .bold)
        let detail = NSTextField(wrappingLabelWithString: "Keep the same Claude Code sessions, skills, and memory across accounts.")
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 0

        let headerText = NSStackView(views: [heading, detail])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 7
        detail.widthAnchor.constraint(equalTo: headerText.widthAnchor).isActive = true
        settingsButton.items = [
            ActionMenuItem("Choose Claude App…") { [weak self] in self?.onAction(.chooseClaude) },
            ActionMenuItem("Copy Diagnostics", symbol: "doc.on.doc") { [weak self] in self?.onAction(.copyDiagnostics) },
            ActionMenuItem("Refresh", symbol: "arrow.clockwise") { [weak self] in self?.onAction(.refresh) },
            .separator(),
            ActionMenuItem("How MacClaude Works", symbol: "questionmark.circle") { [weak self] in self?.onAction(.help) }
        ]
        let header = NSStackView(views: [headerText, settingsButton])
        header.orientation = .horizontal
        header.distribution = .fill
        header.alignment = .top
        header.spacing = 18
        settingsButton.setContentHuggingPriority(.required, for: .horizontal)
        settingsButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        noticeLabel.font = .systemFont(ofSize: 12)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.maximumNumberOfLines = 0
        let noticeIcon = NSImageView(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)!)
        noticeIcon.contentTintColor = .secondaryLabelColor
        noticeIcon.setContentHuggingPriority(.required, for: .horizontal)
        noticeContainer.orientation = .horizontal
        noticeContainer.distribution = .fill
        noticeContainer.alignment = .top
        noticeContainer.spacing = 8
        noticeContainer.addArrangedSubview(noticeIcon)
        let noticeText = NSStackView(views: [noticeLabel, noticeButton])
        noticeText.orientation = .vertical
        noticeText.alignment = .leading
        noticeText.spacing = 8
        noticeLabel.widthAnchor.constraint(equalTo: noticeText.widthAnchor).isActive = true
        noticeButton.widthAnchor.constraint(lessThanOrEqualTo: noticeText.widthAnchor).isActive = true
        noticeButton.cell?.lineBreakMode = .byTruncatingTail
        noticeButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noticeContainer.addArrangedSubview(noticeText)
        noticeContainer.isHidden = true

        let top = NSStackView(views: [header, noticeContainer])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 14
        header.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true
        noticeContainer.widthAnchor.constraint(equalTo: top.widthAnchor).isActive = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .none
        let document = FlippedView()
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10
        rows.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            rows.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)
        ])

        addButton.handler = { [weak self] in self?.onAction(.add) }
        addButton.keyEquivalent = "n"
        addButton.keyEquivalentModifierMask = .command
        addButton.toolTip = "Add an account (⌘N)"
        sharedButton.handler = { [weak self] in self?.onAction(.revealSharedFolder) }
        sharedButton.toolTip = "Open shared Claude Code files in Finder"
        let spacer = NSView()
        let buttonBar = NSStackView(views: [addButton, spacer, sharedButton])
        buttonBar.orientation = .horizontal
        buttonBar.distribution = .fill
        buttonBar.spacing = 10
        addButton.setContentHuggingPriority(.required, for: .horizontal)
        sharedButton.setContentHuggingPriority(.required, for: .horizontal)
        addButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        sharedButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let explanation = NSTextField(wrappingLabelWithString: "Open uses the sessions already in that account. Switch moves the shared Code sessions and restarts Claude. Sign-ins and cloud chats stay with their account.")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 0
        applicationLabel.font = .systemFont(ofSize: 10)
        applicationLabel.textColor = .tertiaryLabelColor
        applicationLabel.lineBreakMode = .byTruncatingMiddle

        let footer = NSStackView(views: [buttonBar, explanation, applicationLabel])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 11
        footer.setCustomSpacing(6, after: explanation)
        buttonBar.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        explanation.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        applicationLabel.widthAnchor.constraint(lessThanOrEqualTo: footer.widthAnchor).isActive = true

        let separator = NSBox()
        separator.boxType = .separator
        for view in [top, scroll, separator, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 25),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -2),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 17),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -19)
        ])
        window.initialFirstResponder = addButton
    }
}

@MainActor
private final class AccountCard: NSView {
    init(account: AccountRowState, index: Int, isBusy: Bool, onAction: @escaping (AccountsAction) -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        setAccessibilityElement(false)

        let avatar = AccountAvatar(name: account.name, index: index)
        let title = NSTextField(labelWithString: account.name)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.toolTip = account.name
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let subtitle = NSTextField(labelWithString: account.holdsSessions ? "Sessions here" : (account.isDefault ? "Original sign-in" : "Separate sign-in"))
        subtitle.toolTip = subtitle.stringValue
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        title.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor).isActive = true
        subtitle.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor).isActive = true
        if let usage = account.usageText, !usage.isEmpty {
            let usageLabel = NSTextField(wrappingLabelWithString: usage)
            usageLabel.font = .systemFont(ofSize: 10)
            usageLabel.toolTip = usage
            usageLabel.textColor = account.usageIsStale ? .tertiaryLabelColor : .secondaryLabelColor
            usageLabel.maximumNumberOfLines = 2
            usageLabel.lineBreakMode = .byTruncatingTail
            labels.addArrangedSubview(usageLabel)
            usageLabel.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        }

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.spacing = 8
        if account.isBusy {
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.controlSize = .small
            progress.isIndeterminate = true
            progress.startAnimation(nil)
            progress.setAccessibilityLabel("Opening \(account.name)")
            controls.addArrangedSubview(progress)
            progress.widthAnchor.constraint(equalToConstant: 16).isActive = true
            progress.heightAnchor.constraint(equalToConstant: 16).isActive = true
        } else if account.isRunning {
            let running = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!)
            running.contentTintColor = .systemGreen
            running.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 6, weight: .regular)
            running.toolTip = "Claude is running with this account"
            controls.addArrangedSubview(running)
            running.widthAnchor.constraint(equalToConstant: 8).isActive = true
            let active = NSTextField(labelWithString: "Running")
            active.font = .systemFont(ofSize: 11)
            active.textColor = .secondaryLabelColor
            active.setContentHuggingPriority(.required, for: .horizontal)
            controls.addArrangedSubview(active)
        }
        let opensInPlace = account.holdsSessions
        let open = ActionButton(title: account.isBusy ? "Opening…" : (opensInPlace ? "Open" : "Switch"))
        open.handler = { onAction(.open(account.id)) }
        open.isEnabled = !isBusy && !account.isBusy && account.canOpen
        open.setAccessibilityLabel("\(opensInPlace ? "Open" : "Switch to") \(account.name)")
        open.toolTip = !account.canOpen ? account.blockedReason : (opensInPlace ? "Open this account without moving sessions" : "Move the shared Code sessions here and restart Claude")
        open.widthAnchor.constraint(greaterThanOrEqualToConstant: 62).isActive = true
        open.setContentHuggingPriority(.required, for: .horizontal)
        controls.addArrangedSubview(open)
        let menu = MenuButton(symbol: "ellipsis", accessibilityLabel: "Options for \(account.name)")
        menu.items = [
            ActionMenuItem("Rename…", symbol: "pencil") { onAction(.rename(account.id)) },
            ActionMenuItem("Show Profile in Finder", symbol: "folder") { onAction(.revealProfile(account.id)) },
            .separator(),
            ActionMenuItem("Remove from List…", symbol: "trash", isEnabled: !account.isDefault && !account.isRunning && !account.holdsSessions) { onAction(.remove(account.id)) }
        ]
        menu.isEnabled = !isBusy && !account.isBusy
        controls.addArrangedSubview(menu)
        controls.setHuggingPriority(.required, for: .horizontal)
        controls.setContentHuggingPriority(.required, for: .horizontal)
        controls.setContentCompressionResistancePriority(.required, for: .horizontal)

        let layout = NSStackView(views: [avatar, labels, controls])
        layout.orientation = .horizontal
        layout.distribution = .fill
        layout.alignment = .centerY
        layout.spacing = 13
        layout.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            layout.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            layout.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            layout.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            avatar.widthAnchor.constraint(equalToConstant: 38),
            avatar.heightAnchor.constraint(equalToConstant: 38),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 76)
        ])
    }

    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

@MainActor
private final class AccountAvatar: NSView {
    private let tint: NSColor
    init(name: String, index: Int) {
        let palette: [NSColor] = [.systemOrange, .systemBlue, .systemPurple, .systemTeal, .systemPink, .systemIndigo]
        tint = palette[index % palette.count]
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        let letter = NSTextField(labelWithString: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased())
        letter.font = .systemFont(ofSize: 18, weight: .semibold)
        letter.textColor = tint
        letter.alignment = .center
        letter.translatesAutoresizingMaskIntoConstraints = false
        addSubview(letter)
        NSLayoutConstraint.activate([
            letter.centerXAnchor.constraint(equalTo: centerXAnchor),
            letter.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = tint.withAlphaComponent(0.12).cgColor }
}

@MainActor
private final class ActionButton: NSButton {
    var handler: (() -> Void)?
    init(title: String, symbol: String? = nil) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        font = .systemFont(ofSize: 12)
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            imagePosition = .imageLeading
            imageHugsTitle = true
        }
        target = self
        action = #selector(invoke)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { handler?() }
}

@MainActor
private final class MenuButton: NSButton {
    var items: [NSMenuItem] = []
    init(symbol: String, accessibilityLabel: String) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        contentTintColor = .secondaryLabelColor
        setAccessibilityLabel(accessibilityLabel)
        toolTip = accessibilityLabel
        target = self
        action = #selector(showMenu)
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }
    required init?(coder: NSCoder) { nil }
    @objc private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items { menu.addItem(item) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 3), in: self)
        menu.removeAllItems()
    }
}

@MainActor
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, symbol: String? = nil, isEnabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.isEnabled = isEnabled
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}

@MainActor
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class WindowBackgroundView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
