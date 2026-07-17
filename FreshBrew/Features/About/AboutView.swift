import AppKit
import SwiftUI

struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text(AppIdentity.displayName)
                .font(.title.bold())
            Text("Version \(version)")
                .foregroundStyle(.secondary)
            Text("A focused menu bar utility for Homebrew updates.")
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 340, height: 230)
    }
}
