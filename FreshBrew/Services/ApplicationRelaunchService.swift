import AppKit

enum ApplicationRelaunchError: LocalizedError {
    case invalidApplicationBundle

    var errorDescription: String? {
        switch self {
        case .invalidApplicationBundle:
            "FreshBrew could not prepare a restart from its current location."
        }
    }
}

@MainActor
final class ApplicationRelaunchService {
    typealias BundleValidator = @MainActor (URL) -> Bool
    typealias RelaunchLauncher = @MainActor (URL) throws -> Void
    typealias Terminator = @MainActor () -> Void

    private let bundleURL: URL
    private let bundleValidator: BundleValidator
    private let relaunchLauncher: RelaunchLauncher
    private let terminator: Terminator

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        bundleValidator: @escaping BundleValidator = ApplicationRelaunchService.isValidBundle,
        relaunchLauncher: @escaping RelaunchLauncher = ApplicationRelaunchService.launchRelauncher,
        terminator: @escaping Terminator = { NSApplication.shared.terminate(nil) }
    ) {
        self.bundleURL = bundleURL
        self.bundleValidator = bundleValidator
        self.relaunchLauncher = relaunchLauncher
        self.terminator = terminator
    }

    func relaunch() throws {
        guard bundleValidator(bundleURL) else {
            throw ApplicationRelaunchError.invalidApplicationBundle
        }
        try relaunchLauncher(bundleURL)
        terminator()
    }

    private static func isValidBundle(_ url: URL) -> Bool {
        guard url.pathExtension == "app",
              let bundle = Bundle(url: url),
              let executableURL = bundle.executableURL else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    private static func launchRelauncher(for bundleURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "sleep 1; exec /usr/bin/open -n \"$1\"",
            "freshbrew-relaunch",
            bundleURL.path
        ]
        try process.run()
    }
}
