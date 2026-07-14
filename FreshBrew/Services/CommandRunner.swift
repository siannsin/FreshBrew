import Foundation

struct CommandRequest: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
    }
}

struct CommandResult: Equatable, Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    var combinedOutput: String {
        [standardOutput, standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

protocol CommandRunning: Sendable {
    func run(
        _ request: CommandRequest,
        onOutput: (@Sendable (String) -> Void)?
    ) async throws -> CommandResult
}

final class SystemCommandRunner: CommandRunning, @unchecked Sendable {
    func run(
        _ request: CommandRequest,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandResult {
        let process = Process()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        let standardOutput = LockedDataBuffer()
        let standardError = LockedDataBuffer()

        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(request.environment) {
            _, suppliedValue in suppliedValue
        }
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        standardOutputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            standardOutput.append(data)
            if let chunk = String(data: data, encoding: .utf8) {
                onOutput?(chunk)
            }
        }

        standardErrorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            standardError.append(data)
            if let chunk = String(data: data, encoding: .utf8) {
                onOutput?(chunk)
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finishedProcess in
                standardOutputPipe.fileHandleForReading.readabilityHandler = nil
                standardErrorPipe.fileHandleForReading.readabilityHandler = nil

                standardOutput.append(standardOutputPipe.fileHandleForReading.readDataToEndOfFile())
                standardError.append(standardErrorPipe.fileHandleForReading.readDataToEndOfFile())

                continuation.resume(returning: CommandResult(
                    exitCode: finishedProcess.terminationStatus,
                    standardOutput: standardOutput.stringValue,
                    standardError: standardError.stringValue
                ))
            }

            do {
                try process.run()
            } catch {
                standardOutputPipe.fileHandleForReading.readabilityHandler = nil
                standardErrorPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    var stringValue: String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(decoding: snapshot, as: UTF8.self)
    }
}
