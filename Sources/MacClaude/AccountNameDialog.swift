import AppKit
import MacClaudeCore

@MainActor
final class AccountNameDialog: NSObject, NSTextFieldDelegate {
    private let alert = NSAlert()
    private let field: NSTextField
    private let validation = NSTextField(wrappingLabelWithString: "")

    init(title: String, message: String, value: String, button: String) {
        field = NSTextField(string: value)
        super.init()
        alert.messageText = title
        alert.informativeText = message
        field.placeholderString = "Personal, Work, Research…"
        field.setAccessibilityLabel("Account name")
        field.delegate = self
        validation.textColor = .systemRed
        validation.font = .systemFont(ofSize: 11)
        validation.maximumNumberOfLines = 0
        let stack = NSStackView(views: [field, validation])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.widthAnchor.constraint(equalToConstant: 310).isActive = true
        field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        validation.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        alert.accessoryView = stack
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        updateValidation(showEmpty: false)
    }

    func run() -> String? {
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return try? ProfileStore.validatedName(field.stringValue)
    }

    func controlTextDidChange(_ notification: Notification) { updateValidation(showEmpty: true) }

    private func updateValidation(showEmpty: Bool) {
        var message = ""
        do { _ = try ProfileStore.validatedName(field.stringValue) }
        catch ProfileStoreError.invalidConfiguration(let reason) { message = reason.prefix(1).uppercased() + reason.dropFirst() }
        catch { message = error.localizedDescription }
        let isEmpty = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        validation.stringValue = isEmpty && !showEmpty ? "" : message
        validation.isHidden = validation.stringValue.isEmpty
        alert.buttons[0].isEnabled = message.isEmpty
        alert.layout()
    }
}
