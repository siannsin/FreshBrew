import Foundation

struct UpdateHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let packages: [UpdatedPackage]
    let timestamp: Date

    init(
        id: UUID = UUID(),
        packages: [UpdatedPackage],
        timestamp: Date
    ) {
        self.id = id
        self.packages = packages
        self.timestamp = timestamp
    }
}
