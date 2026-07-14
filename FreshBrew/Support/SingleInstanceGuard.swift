import Foundation

enum SingleInstanceGuard {
    static func shouldTerminateNewInstance(
        currentProcessIdentifier: pid_t,
        runningProcessIdentifiers: [pid_t]
    ) -> Bool {
        runningProcessIdentifiers.contains { $0 != currentProcessIdentifier }
    }
}
