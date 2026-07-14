import Foundation

struct UpdateProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case preparing
        case upgrading
        case reinstalling
        case verifying
    }

    let stage: Stage
    let packageName: String?
    let message: String
}
