import Foundation

struct AdminAuthorizationContext: Sendable {
    let passwordFileURL: URL
    let askpassScriptURL: URL

    var environment: [String: String] {
        [
            "SUDO_ASKPASS": askpassScriptURL.path,
            "SUDO_ASKPASS_REQUIRE": "force"
        ]
    }

    static func create(
        password: String,
        directory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> AdminAuthorizationContext {
        let identifier = UUID().uuidString.lowercased()
        let passwordFileURL = directory.appendingPathComponent("freshbrew-pw-\(identifier).txt")
        let askpassScriptURL = directory.appendingPathComponent("freshbrew-askpass-\(identifier).sh")

        guard fileManager.createFile(
            atPath: passwordFileURL.path,
            contents: Data(password.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let escapedPasswordPath = passwordFileURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = "#!/bin/sh\n/bin/cat '\(escapedPasswordPath)'\n"
        guard fileManager.createFile(
            atPath: askpassScriptURL.path,
            contents: Data(script.utf8),
            attributes: [.posixPermissions: 0o700]
        ) else {
            try? fileManager.removeItem(at: passwordFileURL)
            throw CocoaError(.fileWriteUnknown)
        }

        return AdminAuthorizationContext(
            passwordFileURL: passwordFileURL,
            askpassScriptURL: askpassScriptURL
        )
    }

    func removeFiles(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: passwordFileURL)
        try? fileManager.removeItem(at: askpassScriptURL)
    }
}
