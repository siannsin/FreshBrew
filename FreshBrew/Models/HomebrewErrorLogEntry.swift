import Foundation

struct HomebrewErrorLogEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let operation: String
    let output: String
    let timestamp: Date

    init(
        id: UUID = UUID(),
        operation: String,
        output: String,
        timestamp: Date
    ) {
        self.id = id
        self.operation = operation
        self.output = output
        self.timestamp = timestamp
    }
}
