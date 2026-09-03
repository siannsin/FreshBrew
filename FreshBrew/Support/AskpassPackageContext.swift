import Foundation

final class AskpassPackageContextSession: @unchecked Sendable {
    static let environmentKey = "HOMEBREW_FRESHBREW_PACKAGE_CONTEXT"

    let contextFileURL: URL

    private let directoryURL: URL
    private let selectedPackageIDs: Set<String>
    private let fileManager: FileManager
    private let lock = NSLock()
    private var isCleared = false

    convenience init(selectedPackageIDs: Set<String>) throws {
        try self.init(
            selectedPackageIDs: selectedPackageIDs,
            parentDirectoryURL: FileManager.default.temporaryDirectory
        )
    }

    init(
        selectedPackageIDs: Set<String>,
        parentDirectoryURL: URL,
        fileManager: FileManager = .default
    ) throws {
        self.selectedPackageIDs = selectedPackageIDs
        self.fileManager = fileManager
        directoryURL = parentDirectoryURL.appendingPathComponent(
            "freshbrew-askpass-\(UUID().uuidString)",
            isDirectory: true
        )
        contextFileURL = directoryURL.appendingPathComponent("package-context")

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    deinit {
        try? fileManager.removeItem(at: directoryURL)
    }

    @discardableResult
    func setCurrentPackage(id packageID: String?) -> Bool {
        lock.withLock {
            guard !isCleared else { return false }
            guard let packageID else {
                try? fileManager.removeItem(at: contextFileURL)
                return true
            }
            guard selectedPackageIDs.contains(packageID),
                  Self.packageName(fromIdentifier: packageID) != nil else {
                try? fileManager.removeItem(at: contextFileURL)
                return false
            }

            do {
                try Data(packageID.utf8).write(to: contextFileURL, options: .atomic)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: contextFileURL.path
                )
                return true
            } catch {
                try? fileManager.removeItem(at: contextFileURL)
                return false
            }
        }
    }

    func clear() {
        lock.withLock {
            guard !isCleared else { return }
            isCleared = true
            try? fileManager.removeItem(at: directoryURL)
        }
    }

    static func currentPackageName(
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> String? {
        guard let path = environment[environmentKey], !path.isEmpty else {
            return nil
        }

        let url = URL(fileURLWithPath: path)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0,
              size.intValue <= 512,
              let data = try? Data(contentsOf: url),
              let identifier = String(data: data, encoding: .utf8) else {
            return nil
        }

        return packageName(
            fromIdentifier: identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func packageName(fromIdentifier identifier: String) -> String? {
        let parts = identifier.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              parts[0] == "formula" || parts[0] == "cask" else {
            return nil
        }

        let name = String(parts[1])
        guard !name.isEmpty,
              name.count <= 160,
              name.unicodeScalars.allSatisfy(Self.allowedNameCharacters.contains) else {
            return nil
        }
        return name
    }

    private static let allowedNameCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@+_.-/"
    )
}
