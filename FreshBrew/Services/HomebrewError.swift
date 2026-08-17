import Foundation

enum HomebrewError: Error, Equatable, Sendable {
    case executableNotFound(URL)
    case commandFailed(HomebrewCommandFailure)
    case permissionRequired(String)
    case existingApplicationConflict(path: String, output: String)
    case invalidRecoveryTarget(URL)
    case networkUnavailable
    case timedOut(operation: String, seconds: TimeInterval, output: String)
}

extension HomebrewError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Homebrew was not found at /opt/homebrew/bin/brew or /usr/local/bin/brew."
        case let .commandFailed(failure):
            if Self.outputIndicatesNetworkFailure(failure.output) {
                return "Network unavailable. Check your connection and try again."
            }
            return "Homebrew could not complete the operation."
        case .permissionRequired:
            return "Homebrew requires administrator access."
        case let .existingApplicationConflict(path, _):
            return "An existing app at \(path) is blocking the cask operation."
        case .invalidRecoveryTarget:
            return "The selected path is not a valid application bundle for cask recovery."
        case .networkUnavailable:
            return "Network unavailable. Check your connection and try again."
        case let .timedOut(operation, seconds, _):
            return "\(operation.capitalized) timed out after \(Self.formattedDuration(seconds))."
        }
    }

    private static func formattedDuration(_ seconds: TimeInterval) -> String {
        let roundedSeconds = Int(seconds.rounded())
        if roundedSeconds.isMultiple(of: 60) {
            let minutes = roundedSeconds / 60
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        return "\(roundedSeconds) second\(roundedSeconds == 1 ? "" : "s")"
    }
}

extension HomebrewError {
    var indicatesNetworkFailure: Bool {
        switch self {
        case .networkUnavailable:
            return true
        case let .commandFailed(failure):
            return Self.outputIndicatesNetworkFailure(failure.output)
        default:
            return false
        }
    }

    static func outputIndicatesNetworkFailure(_ output: String) -> Bool {
        let normalizedOutput = output.lowercased()
        let networkMarkers = [
            "could not resolve host",
            "could not resolve hostname",
            "could not resolve proxy",
            "failed to connect to",
            "could not connect to server",
            "couldn't connect to server",
            "network is unreachable",
            "no route to host",
            "temporary failure in name resolution",
            "nodename nor servname provided",
            "name or service not known"
        ]
        return networkMarkers.contains(where: normalizedOutput.contains)
    }

    static func classified(
        operation: String,
        exitCode: Int32,
        output: String
    ) -> HomebrewError {
        if let path = existingApplicationPath(in: output) {
            return .existingApplicationConflict(path: path, output: output)
        }

        let normalizedOutput = output.lowercased()
        let permissionMarkers = [
            "permission denied",
            "operation not permitted",
            "password is required",
            "requires root",
            "sudo:"
        ]

        if permissionMarkers.contains(where: normalizedOutput.contains) {
            return .permissionRequired(output)
        }

        return .commandFailed(HomebrewCommandFailure(
            operation: operation,
            exitCode: exitCode,
            output: output
        ))
    }

    static func existingApplicationPath(in output: String) -> String? {
        let marker = "already an App at '"
        guard let markerRange = output.range(of: marker),
              let closingQuote = output[markerRange.upperBound...].firstIndex(of: "'") else {
            return nil
        }

        return String(output[markerRange.upperBound..<closingQuote])
    }
}
