import Foundation
import XCTest
@testable import FreshBrew

final class CommandRunnerTests: XCTestCase {
    private static let fixtureTimeout: TimeInterval = 10
    private static let commandSafetyTimeout: TimeInterval = 15

    func testMergedPipeOutputMergesStreamsWithoutMakingInputATerminal() async throws {
        let result = try await SystemCommandRunner().run(CommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "! test -t 1 && ! test -t 2 && ! test -t 0 && printf 'output\\n' && printf 'error\\n' >&2"],
            timeoutPolicy: CommandTimeoutPolicy(absoluteLimit: 5),
            outputMode: .mergedPipes
        ))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "output\nerror\n")
        XCTAssertEqual(result.standardError, "")
    }

    func testMergedPipeDeliversProgressBeforeCommandExit() async throws {
        let releaseURL = temporaryMarkerURL()
        defer { try? FileManager.default.removeItem(at: releaseURL) }

        let progress = expectation(description: "Progress is delivered while command is running")
        progress.assertForOverFulfill = false
        let request = CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/ruby"),
            arguments: [
                "-e",
                "$stdout.sync = true; puts '==> Upgrading wget'; sleep 0.01 until File.exist?(ARGV.fetch(0))",
                releaseURL.path
            ],
            timeoutPolicy: CommandTimeoutPolicy(absoluteLimit: Self.commandSafetyTimeout),
            outputMode: .mergedPipes
        )
        let onOutput: @Sendable (String) -> Void = { chunk in
            if chunk.contains("==> Upgrading wget") { progress.fulfill() }
        }
        let task = Task {
            try await SystemCommandRunner().run(request, onOutput: onOutput)
        }
        defer { task.cancel() }

        await fulfillment(of: [progress], timeout: Self.fixtureTimeout)
        try Data().write(to: releaseURL, options: .atomic)
        let result = try await task.value

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.contains("==> Upgrading wget"))
    }

    func testMergedPipeCancellationStopsRunningCommand() async throws {
        let startedURL = temporaryMarkerURL()
        let request = CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/ruby"),
            arguments: [
                "-e",
                "File.write(ARGV.fetch(0), 'started'); sleep 30",
                startedURL.path
            ],
            timeoutPolicy: CommandTimeoutPolicy(absoluteLimit: Self.commandSafetyTimeout),
            outputMode: .mergedPipes
        )
        let task = Task {
            try await SystemCommandRunner().run(request)
        }
        defer {
            task.cancel()
            try? FileManager.default.removeItem(at: startedURL)
        }

        let didStart = try await waitForFile(at: startedURL, timeout: Self.fixtureTimeout)
        XCTAssertTrue(didStart, "Child process did not start within the fixture timeout")
        guard didStart else {
            task.cancel()
            _ = try? await task.value
            return
        }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // The running child must stop without waiting for Ruby's sleep.
        }
    }

    func testMergedPipeTimeoutsPreserveOutput() async throws {
        for reason in [CommandTimeoutReason.absolute, .inactivity] {
            do {
                _ = try await SystemCommandRunner().run(CommandRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "printf started; sleep 30"],
                    timeoutPolicy: CommandTimeoutPolicy(
                        absoluteLimit: reason == .absolute ? 0.5 : 5,
                        inactivityLimit: reason == .inactivity ? 0.5 : nil
                    ),
                    outputMode: .mergedPipes
                ))
                XCTFail("Expected timeout")
            } catch let error as CommandTimeoutError {
                XCTAssertEqual(error.reason, reason)
                XCTAssertTrue(error.output.contains("started"))
            }
        }
    }

    func testMergedPipeHandlesLargeOutputAndNonzeroExit() async throws {
        let result = try await SystemCommandRunner().run(CommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/usr/bin/seq 1 5000; printf failure >&2; exit 7"],
            timeoutPolicy: CommandTimeoutPolicy(absoluteLimit: 5),
            outputMode: .mergedPipes
        ))
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertTrue(result.standardOutput.hasPrefix("1\n2\n"))
        XCTAssertTrue(result.standardOutput.hasSuffix("5000\nfailure"))
    }

    func testMergedPipeOutputResetsInactivityTimeout() async throws {
        let result = try await SystemCommandRunner().run(CommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf first; sleep 0.3; printf second; sleep 0.3; printf third"],
            timeoutPolicy: CommandTimeoutPolicy(absoluteLimit: 5, inactivityLimit: 0.5),
            outputMode: .mergedPipes
        ))
        XCTAssertEqual(result.standardOutput, "firstsecondthird")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testMergedPipeLaunchFailureReturnsAnError() async {
        do {
            _ = try await SystemCommandRunner().run(CommandRequest(
                executableURL: URL(fileURLWithPath: "/nonexistent/FreshBrew-test-command"),
                arguments: [],
                outputMode: .mergedPipes
            ))
            XCTFail("Expected launch failure")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testMergedPipeStartupCancellationDoesNotCloseLaunchHandles() async throws {
        for index in 0..<200 {
            let task = Task {
                try await SystemCommandRunner().run(CommandRequest(
                    executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                    arguments: [],
                    outputMode: .mergedPipes
                ))
            }
            try await Task.sleep(nanoseconds: UInt64(index % 5) * 50_000)
            task.cancel()
            do {
                let result = try await task.value
                XCTAssertEqual(result.exitCode, 0)
            } catch is CancellationError {
                // Cancellation can race launch or a very short command's exit.
            }
        }
    }

    func testMergedPipeDoesNotEnableSpinnerThatMasksInactivity() async throws {
        let script = """
        $stdout.sync = true if ENV['CI']
        puts 'waiting for download'
        if STDOUT.tty?
          loop { print "\\rwaiting for download"; sleep 0.05 }
        else
          sleep 30
        end
        """
        do {
            _ = try await SystemCommandRunner().run(CommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/ruby"),
                arguments: ["-e", script],
                environment: ["CI": "1"],
                timeoutPolicy: CommandTimeoutPolicy(absoluteLimit: 3, inactivityLimit: 0.5),
                outputMode: .mergedPipes
            ))
            XCTFail("Expected a stalled download to time out")
        } catch let error as CommandTimeoutError {
            XCTAssertEqual(error.reason, .inactivity)
            XCTAssertTrue(error.output.contains("waiting for download"))
        }
    }

    func testSystemRunnerCapturesStandardOutputAndError() async throws {
        let runner = SystemCommandRunner()
        let result = try await runner.run(
            CommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf standard-output; printf standard-error >&2"]
            ),
            onOutput: nil
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "standard-output")
        XCTAssertEqual(result.standardError, "standard-error")
        XCTAssertTrue(result.combinedOutput.contains("standard-output"))
        XCTAssertTrue(result.combinedOutput.contains("standard-error"))
    }

    func testSystemRunnerHandlesLargeOutputWithoutBlocking() async throws {
        let runner = SystemCommandRunner()
        let result = try await runner.run(
            CommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/seq"),
                arguments: ["1", "5000"]
            ),
            onOutput: nil
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.hasPrefix("1\n2\n"))
        XCTAssertTrue(result.standardOutput.hasSuffix("5000\n"))
    }

    func testSystemRunnerStopsAtAbsoluteTimeoutAndPreservesOutput() async throws {
        let runner = SystemCommandRunner()

        do {
            _ = try await runner.run(
                CommandRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "printf started; sleep 30"],
                    timeoutPolicy: CommandTimeoutPolicy(absoluteLimit: 0.5)
                ),
                onOutput: nil
            )
            XCTFail("Expected an absolute timeout")
        } catch let error as CommandTimeoutError {
            XCTAssertEqual(error.reason, .absolute)
            XCTAssertEqual(error.limit, 0.5)
            XCTAssertTrue(error.output.contains("started"))
        }
    }

    func testSystemRunnerStopsAfterInactivity() async throws {
        let runner = SystemCommandRunner()

        do {
            _ = try await runner.run(
                CommandRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "printf started; sleep 30"],
                    timeoutPolicy: CommandTimeoutPolicy(
                        absoluteLimit: 5,
                        inactivityLimit: 0.5
                    )
                ),
                onOutput: nil
            )
            XCTFail("Expected an inactivity timeout")
        } catch let error as CommandTimeoutError {
            XCTAssertEqual(error.reason, .inactivity)
            XCTAssertEqual(error.limit, 0.5)
            XCTAssertTrue(error.output.contains("started"))
        }
    }

    func testSystemRunnerOutputResetsInactivityTimeout() async throws {
        let runner = SystemCommandRunner()
        let result = try await runner.run(
            CommandRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "printf first >&2; sleep 0.2; printf second >&2; sleep 0.2; printf third >&2"
                ],
                timeoutPolicy: CommandTimeoutPolicy(
                    absoluteLimit: 3,
                    inactivityLimit: 0.4
                )
            ),
            onOutput: nil
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardError, "firstsecondthird")
    }

    private func temporaryMarkerURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("freshbrew-command-runner-\(UUID().uuidString)")
    }

    private func waitForFile(at url: URL, timeout: TimeInterval) async throws -> Bool {
        let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds

        while DispatchTime.now().uptimeNanoseconds < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        return FileManager.default.fileExists(atPath: url.path)
    }
}
