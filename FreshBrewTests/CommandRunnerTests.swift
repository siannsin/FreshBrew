import Foundation
import XCTest
@testable import FreshBrew

final class CommandRunnerTests: XCTestCase {
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
}
