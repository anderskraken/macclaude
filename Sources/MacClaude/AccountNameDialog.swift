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
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let message: String
        if value.isEmpty { message = showEmpty ? "Enter an account name." : "" }
        else if value.count > 60 { message = "Use 60 characters or fewer." }
        else if value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            message = "Remove line breaks or control characters."
        } else { message = "" }
        validation.stringValue = message
        validation.isHidden = message.isEmpty
        alert.buttons[0].isEnabled = (try? ProfileStore.validatedName(field.stringValue)) != nil
        alert.layout()
    }
}
