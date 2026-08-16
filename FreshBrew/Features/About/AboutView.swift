import AppKit
import SwiftUI

struct AboutView: View {
    @ObservedObject var applicationUpdateCoordinator: ApplicationUpdateCoordinator

    var body: some View {
        VStack(spacing: 0) {
            identityContent

            Divider()
                .frame(width: 260)
                .padding(.vertical, 12)

            updateContent
        }
        .padding(20)
        .frame(width: 340, height: 310)
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

            Text("A menu bar utility for Homebrew updates.")
                .multilineTextAlignment(.center)
        }
    }

    private var updateContent: some View {
        VStack(spacing: 10) {
            updateStatus
                .frame(maxWidth: .infinity)

            updateAction

            Toggle(
                "Check automatically",
                isOn: $applicationUpdateCoordinator.checksEnabled
            )
            .toggleStyle(.checkbox)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch applicationUpdateCoordinator.manualState {
        case .idle:
            Text("Not checked yet")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking for updates…")
                    .foregroundStyle(.secondary)
            }
        case .current:
            Text("FreshBrew is up to date.")
                .foregroundStyle(.secondary)
        case let .updateAvailable(release):
            Text("FreshBrew \(release.displayVersion) is available.")
                .foregroundStyle(.secondary)
        case let .failed(message):
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var updateAction: some View {
        switch applicationUpdateCoordinator.manualState {
        case .updateAvailable:
            Button("View Release") {
                _ = applicationUpdateCoordinator.openAvailableRelease()
            }
        case .idle, .checking:
            checkButton(title: "Check for Updates")
        case .current:
            checkButton(title: "Check Again")
        case .failed:
            checkButton(title: "Try Again")
        }
    }

    private func checkButton(title: String) -> some View {
        Button(title) {
            Task { await applicationUpdateCoordinator.checkManually() }
        }
        .disabled(applicationUpdateCoordinator.isChecking)
    }
}
