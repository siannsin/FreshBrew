import Foundation

struct CleanupResult: Codable, Hashable, Sendable {
    let isDeepCleanup: Bool
    let output: String
    let completedAt: Date

    var freedSpaceDescription: String? {
        let pattern = #"freed approximately\s+(.+?)\s+of disk space"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = expression.firstMatch(in: output, range: range),
              let valueRange = Range(match.range(at: 1), in: output) else {
            return nil
        }

        let value = output[valueRange].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let zeroSizePattern = #"^0+(?:\.0+)?\s*[A-Za-z]"#
        if value.range(of: zeroSizePattern, options: .regularExpression) != nil {
            return nil
        }
        return value
    }
}
