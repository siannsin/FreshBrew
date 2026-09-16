import AppKit
import Darwin
import Foundation

@MainActor
private func requestPassword() -> AskpassResponse {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    let alert = NSAlert()
    alert.messageText = "Homebrew needs admin access"
    let packageName = AskpassPackageContextSession.currentPackageName(
        environment: ProcessInfo.processInfo.environment
    )
    alert.informativeText = AskpassPromptContent.informativeText(
        packageName: packageName
    )
    alert.alertStyle = .informational
    let contentsURL = URL(fileURLWithPath: CommandLine.arguments[0])
        .standardizedFileURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let iconURL = contentsURL.appendingPathComponent("Resources/AppIcon.icns")
    alert.icon = NSImage(contentsOf: iconURL)
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")

    let passwordField = NSSecureTextField(
        frame: NSRect(x: 0, y: 0, width: 230, height: 24)
    )
    passwordField.placeholderString = "Password"
    alert.accessoryView = passwordField
    alert.layout()

    let alertWindow = alert.window
    alertWindow.initialFirstResponder = passwordField
    application.activate(ignoringOtherApps: true)
    DispatchQueue.main.async {
        application.activate(ignoringOtherApps: true)
        alertWindow.makeKey()
        alertWindow.makeFirstResponder(passwordField)
    }

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
