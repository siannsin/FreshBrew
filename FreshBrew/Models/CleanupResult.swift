import Foundation

struct CleanupResult: Codable, Hashable, Sendable {
    let isDeepCleanup: Bool
    let output: String
    let completedAt: Date
}
