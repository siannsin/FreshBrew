import AppKit
import SwiftUI

struct AboutView: View {
    @ObservedObject var applicationUpdateCoordinator: ApplicationUpdateCoordinator

    var body: some View {
        VStack(spacing: 16) {
            identityContent
            updateContent
        }
        .padding(20)
        .frame(width: 340, height: 240)
    }

    private var identityContent: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(AppIdentity.displayName)
                    .font(.title.bold())
                Text("Version \(AppIdentity.marketingVersion)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var updateContent: some View {
        VStack(spacing: 10) {
            updateAction

            Toggle(
                "Automatic Checks",
                isOn: $applicationUpdateCoordinator.checksEnabled
            )
            .toggleStyle(.checkbox)
            .fixedSize()
        }
    }

    private var updateAction: some View {
        Button(action: performUpdateAction) {
            updateActionLabel
                .frame(width: 120)
        }
        .disabled(applicationUpdateCoordinator.isChecking)
        .help(updateActionHelp)
    }

    @ViewBuilder
    private var updateActionLabel: some View {
        switch applicationUpdateCoordinator.manualState {
        case .idle:
            Text("Check Updates")
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking…")
            }
        case .current:
            Label("Check Again", systemImage: "checkmark")
        case let .updateAvailable(release):
            Text("\(release.displayVersion) available")
        case .failed:
            Label("Try Again", systemImage: "exclamationmark.triangle")
        }
    }

    private var updateActionHelp: String {
        switch applicationUpdateCoordinator.manualState {
        case .idle:
            "Check for a newer \(AppIdentity.displayName) release."
        case .checking:
            "Checking for a newer \(AppIdentity.displayName) release."
        case .current:
            "\(AppIdentity.displayName) is up to date."
        case let .updateAvailable(release):
            "View \(AppIdentity.displayName) \(release.displayVersion) on GitHub."
        case let .failed(message):
            message
        }
    }

    private func performUpdateAction() {
        switch applicationUpdateCoordinator.manualState {
        case .idle, .current, .failed:
            Task { await applicationUpdateCoordinator.checkManually() }
        case .updateAvailable:
            _ = applicationUpdateCoordinator.openAvailableRelease()
        case .checking:
            break
        }
    }
}
