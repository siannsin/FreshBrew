import AppKit
import Darwin
import Foundation

@MainActor
private func requestPassword() -> AskpassResponse {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    application.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.messageText = "FreshBrew needs admin access"
    alert.informativeText = "Enter your login password to update."
    alert.alertStyle = .informational
    let contentsURL = URL(fileURLWithPath: CommandLine.arguments[0])
        .standardizedFileURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let iconURL = contentsURL.appendingPathComponent("Resources/AppIcon.icns")
    alert.icon = NSImage(contentsOf: iconURL)
    alert.addButton(withTitle: "Update")
    alert.addButton(withTitle: "Cancel")

    let passwordField = NSSecureTextField(
        frame: NSRect(x: 0, y: 0, width: 230, height: 24)
    )
    passwordField.placeholderString = "Password"
    alert.accessoryView = passwordField
    alert.window.initialFirstResponder = passwordField

    guard alert.runModal() == .alertFirstButtonReturn else {
        return .cancelled
    }
    return .confirmed(password: passwordField.stringValue)
}

let response = requestPassword()
if !response.standardOutput.isEmpty {
    FileHandle.standardOutput.write(response.standardOutput)
}
exit(response.exitCode)
