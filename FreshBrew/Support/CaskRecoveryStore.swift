import Foundation

struct CaskRecoveryBackup: Equatable, Sendable {
    let originalURL: URL
    let backupURL: URL
}

struct CaskRecoveryStore: Sendable {
    let rootDirectory: URL

    init(rootDirectory: URL = CaskRecoveryStore.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory
    }

    nonisolated static func defaultRootDirectory() -> URL {
        let cachesDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)

        return cachesDirectory
            .appendingPathComponent("FreshBrew", isDirectory: true)
            .appendingPathComponent("CaskRecovery", isDirectory: true)
    }

    func stageApplication(at applicationURL: URL) throws -> CaskRecoveryBackup {
        guard applicationURL.pathExtension.lowercased() == "app" else {
            throw HomebrewError.invalidRecoveryTarget(applicationURL)
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: applicationURL.path) else {
            throw HomebrewError.invalidRecoveryTarget(applicationURL)
        }

        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )

        let backupName = "\(applicationURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.lowercased()).app"
        let backupURL = rootDirectory.appendingPathComponent(backupName, isDirectory: true)
        try fileManager.moveItem(at: applicationURL, to: backupURL)
        return CaskRecoveryBackup(originalURL: applicationURL, backupURL: backupURL)
    }

    func restore(_ backup: CaskRecoveryBackup) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: backup.backupURL.path) else { return }

        if fileManager.fileExists(atPath: backup.originalURL.path) {
            let preservedName = "failed-\(UUID().uuidString.lowercased())-\(backup.originalURL.lastPathComponent)"
            let preservedURL = rootDirectory.appendingPathComponent(preservedName, isDirectory: true)
            try fileManager.moveItem(at: backup.originalURL, to: preservedURL)
        }

        try fileManager.moveItem(at: backup.backupURL, to: backup.originalURL)
    }

    func discard(_ backup: CaskRecoveryBackup) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: backup.backupURL.path) {
            try fileManager.removeItem(at: backup.backupURL)
        }
    }

    @discardableResult
    func removeBackups(olderThan cutoff: Date) throws -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return [] }

        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
        let urls = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        var removedURLs: [URL] = []

        for url in urls {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isDirectory == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt < cutoff else {
                continue
            }
            try fileManager.removeItem(at: url)
            removedURLs.append(url)
        }

        return removedURLs
    }
}
