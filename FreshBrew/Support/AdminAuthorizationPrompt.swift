import AppKit

@MainActor
protocol AdminPasswordPrompting {
    func requestPassword() async -> String?
}

@MainActor
struct AdminAuthorizationPrompt: AdminPasswordPrompting {
    func requestPassword() async -> String? {
        let alert = NSAlert()
        alert.messageText = "FreshBrew needs administrator access"
        alert.informativeText = "Enter your macOS password so Homebrew can finish this update."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        passwordField.placeholderString = "Password"
        alert.accessoryView = passwordField
        alert.window.initialFirstResponder = passwordField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return passwordField.stringValue.isEmpty ? nil : passwordField.stringValue
    }
}
