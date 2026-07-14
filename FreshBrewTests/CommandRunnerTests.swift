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
}
