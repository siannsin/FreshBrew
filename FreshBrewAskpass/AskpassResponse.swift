import Foundation

struct AskpassResponse: Equatable, Sendable {
    static let cancelled = AskpassResponse(exitCode: 1, standardOutput: Data())

    let exitCode: Int32
    let standardOutput: Data

    static func confirmed(password: String) -> AskpassResponse {
        guard !password.isEmpty else { return .cancelled }
        return AskpassResponse(
            exitCode: 0,
            standardOutput: Data("\(password)\n".utf8)
        )
    }
}
