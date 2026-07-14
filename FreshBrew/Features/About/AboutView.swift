import SwiftUI

struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 52))
                .symbolRenderingMode(.hierarchical)
            Text(AppIdentity.displayName)
                .font(.title.bold())
            Text("Version \(version)")
                .foregroundStyle(.secondary)
            Text("A focused menu bar utility for Homebrew updates.")
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(width: 360, height: 260)
    }
}
