import Foundation
import Darwin

struct CommandTimeoutPolicy: Equatable, Sendable {
    let absoluteLimit: TimeInterval
    let inactivityLimit: TimeInterval?

    init(absoluteLimit: TimeInterval, inactivityLimit: TimeInterval? = nil) {
        self.absoluteLimit = absoluteLimit
        self.inactivityLimit = inactivityLimit
    }
}

enum CommandTimeoutReason: Equatable, Sendable {
    case absolute
    case inactivity
}

struct CommandTimeoutError: Error, Equatable, Sendable {
    let reason: CommandTimeoutReason
    let limit: TimeInterval
    let output: String
}

struct CommandRequest: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let timeoutPolicy: CommandTimeoutPolicy?

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        timeoutPolicy: CommandTimeoutPolicy? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.timeoutPolicy = timeoutPolicy
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
        let execution = CommandExecution(request: request, onOutput: onOutput)
        return try await withTaskCancellationHandler {
            try await execution.start()
        } onCancel: {
            execution.cancel()
        }
    }
}

private final class CommandExecution: @unchecked Sendable {
    private enum CompletionCause {
        case normal
        case cancelled
        case timedOut(reason: CommandTimeoutReason, limit: TimeInterval)
    }

    private let request: CommandRequest
    private let onOutput: (@Sendable (String) -> Void)?
    private let process = Process()
    private let standardOutputPipe = Pipe()
    private let standardErrorPipe = Pipe()
    private let standardOutput = LockedDataBuffer()
    private let standardError = LockedDataBuffer()
    private let lock = NSLock()
    private let timerQueue = DispatchQueue(label: "net.siann.freshbrew.command-timeout")

    private var continuation: CheckedContinuation<CommandResult, Error>?
    private var timer: DispatchSourceTimer?
    private var completionCause: CompletionCause = .normal
    private var isComplete = false
    private var hasStarted = false
    private var startUptime: UInt64 = 0
    private var lastOutputUptime: UInt64 = 0
    private var processIdentifier: pid_t?
    private var capturedDescendantPIDs: [pid_t] = []

    init(
        request: CommandRequest,
        onOutput: (@Sendable (String) -> Void)?
    ) {
        self.request = request
        self.onOutput = onOutput
    }

    func start() async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if isComplete {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            lock.unlock()

            configureProcess()

            lock.lock()
            let shouldStart = !isComplete
            lock.unlock()
            guard shouldStart else { return }

            do {
                try process.run()
                didStartProcess()
            } catch {
                finish(throwing: error)
            }
        }
    }

    func cancel() {
        requestStop(cause: .cancelled)
    }

    private func configureProcess() {
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(request.environment) {
            _, suppliedValue in suppliedValue
        }
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        standardOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData, isStandardError: false)
        }
        standardErrorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData, isStandardError: true)
        }
        process.terminationHandler = { [weak self] finishedProcess in
            self?.processDidTerminate(finishedProcess)
        }
    }

    private func didStartProcess() {
        let uptime = DispatchTime.now().uptimeNanoseconds
        var shouldStopImmediately = false

        lock.lock()
        hasStarted = true
        processIdentifier = process.processIdentifier
        startUptime = uptime
        lastOutputUptime = uptime
        if case .normal = completionCause {
            startTimerIfNeededLocked()
        } else {
            shouldStopImmediately = true
        }
        lock.unlock()

        if shouldStopImmediately {
            terminateProcessTree()
        }
    }

    private func receive(_ data: Data, isStandardError: Bool) {
        guard !data.isEmpty else { return }
        if isStandardError {
            standardError.append(data)
        } else {
            standardOutput.append(data)
        }

        lock.lock()
        lastOutputUptime = DispatchTime.now().uptimeNanoseconds
        lock.unlock()

        if let chunk = String(data: data, encoding: .utf8) {
            onOutput?(chunk)
        }
    }

    private func startTimerIfNeededLocked() {
        guard request.timeoutPolicy != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            self?.evaluateTimeout()
        }
        self.timer = timer
        timer.resume()
    }

    private func evaluateTimeout() {
        guard let policy = request.timeoutPolicy else { return }
        let uptime = DispatchTime.now().uptimeNanoseconds
        var timeout: (CommandTimeoutReason, TimeInterval)?

        lock.lock()
        if !isComplete, case .normal = completionCause {
            if Self.elapsedSeconds(from: startUptime, to: uptime) >= policy.absoluteLimit {
                timeout = (.absolute, policy.absoluteLimit)
            } else if let inactivityLimit = policy.inactivityLimit,
                      Self.elapsedSeconds(from: lastOutputUptime, to: uptime) >= inactivityLimit {
                timeout = (.inactivity, inactivityLimit)
            }
        }
        lock.unlock()

        if let timeout {
            requestStop(cause: .timedOut(reason: timeout.0, limit: timeout.1))
        }
    }

    private func requestStop(cause: CompletionCause) {
        var shouldTerminate = false
        var shouldFinishCancellation = false

        lock.lock()
        guard !isComplete, case .normal = completionCause else {
            lock.unlock()
            return
        }
        completionCause = cause
        timer?.cancel()
        timer = nil
        if hasStarted {
            shouldTerminate = true
        } else if case .cancelled = cause, continuation != nil {
            shouldFinishCancellation = true
        }
        lock.unlock()

        if shouldTerminate {
            terminateProcessTree()
        } else if shouldFinishCancellation {
            finish(throwing: CancellationError())
        }
    }

    private func terminateProcessTree() {
        lock.lock()
        guard let rootPID = processIdentifier else {
            lock.unlock()
            return
        }
        let descendants = Self.descendantProcessIdentifiers(of: rootPID)
        capturedDescendantPIDs = descendants
        lock.unlock()

        for pid in descendants.reversed() {
            Darwin.kill(pid, SIGTERM)
        }
        Darwin.kill(rootPID, SIGTERM)

        timerQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.forceKillCapturedProcessTree(rootPID: rootPID)
        }
    }

    private func forceKillCapturedProcessTree(rootPID: pid_t) {
        lock.lock()
        guard !isComplete else {
            lock.unlock()
            return
        }
        let descendants = capturedDescendantPIDs
        lock.unlock()

        for pid in descendants.reversed() where Darwin.kill(pid, 0) == 0 {
            Darwin.kill(pid, SIGKILL)
        }
        if Darwin.kill(rootPID, 0) == 0 {
            Darwin.kill(rootPID, SIGKILL)
        }
    }

    private func processDidTerminate(_ finishedProcess: Process) {
        standardOutputPipe.fileHandleForReading.readabilityHandler = nil
        standardErrorPipe.fileHandleForReading.readabilityHandler = nil
        standardOutput.append(standardOutputPipe.fileHandleForReading.readDataToEndOfFile())
        standardError.append(standardErrorPipe.fileHandleForReading.readDataToEndOfFile())

        lock.lock()
        let cause = completionCause
        lock.unlock()

        switch cause {
        case .normal:
            finish(returning: CommandResult(
                exitCode: finishedProcess.terminationStatus,
                standardOutput: standardOutput.stringValue,
                standardError: standardError.stringValue
            ))
        case .cancelled:
            finish(throwing: CancellationError())
        case let .timedOut(reason, limit):
            finish(throwing: CommandTimeoutError(
                reason: reason,
                limit: limit,
                output: combinedOutput
            ))
        }
    }

    private func finish(returning result: CommandResult) {
        let continuation = takeContinuationForCompletion()
        continuation?.resume(returning: result)
    }

    private func finish(throwing error: Error) {
        let continuation = takeContinuationForCompletion()
        continuation?.resume(throwing: error)
    }

    private func takeContinuationForCompletion() -> CheckedContinuation<CommandResult, Error>? {
        lock.lock()
        guard !isComplete else {
            lock.unlock()
            return nil
        }
        isComplete = true
        timer?.cancel()
        timer = nil
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        standardOutputPipe.fileHandleForReading.readabilityHandler = nil
        standardErrorPipe.fileHandleForReading.readabilityHandler = nil
        return continuation
    }

    private var combinedOutput: String {
        [standardOutput.stringValue, standardError.stringValue]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func elapsedSeconds(from start: UInt64, to end: UInt64) -> TimeInterval {
        guard end >= start else { return 0 }
        return TimeInterval(end - start) / 1_000_000_000
    }

    private static func descendantProcessIdentifiers(of parentPID: pid_t) -> [pid_t] {
        let bufferSize = proc_listchildpids(parentPID, nil, 0)
        guard bufferSize > 0 else { return [] }

        let capacity = Int(bufferSize)
        var children = Array(repeating: pid_t(0), count: capacity)
        let childCount = children.withUnsafeMutableBytes { buffer in
            proc_listchildpids(parentPID, buffer.baseAddress, Int32(buffer.count))
        }
        guard childCount > 0 else { return [] }

        children = Array(children.prefix(Int(childCount)).filter { $0 > 0 })
        return children + children.flatMap { descendantProcessIdentifiers(of: $0) }
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
