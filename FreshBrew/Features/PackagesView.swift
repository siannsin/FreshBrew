import Combine
import SwiftUI

@MainActor
final class PackagesWindowState: ObservableObject {
    enum Tab: Hashable {
        case installed
        case history
        case skipped
    }

    @Published var selectedTab: Tab = .installed
}

struct PackagesView: View {
    @ObservedObject var model: MenuBarModel
    @ObservedObject var windowState: PackagesWindowState
    let openPackageHomepage: (String, HomebrewPackageKind, URL?) -> Void

    var body: some View {
        TabView(selection: Binding(
            get: { windowState.selectedTab },
            set: { tab in
                guard tab != windowState.selectedTab else { return }
                // Native title-bar tabs can write selection during a SwiftUI view update.
                DispatchQueue.main.async { windowState.selectedTab = tab }
            }
        )) {
            InstalledPackagesView(model: model, openPackageHomepage: openPackageHomepage)
                .tabItem { Text("Installed") }
                .tag(PackagesWindowState.Tab.installed)

            HistoryView(model: model, openPackageHomepage: openPackageHomepage)
                .tabItem { Text("History") }
                .tag(PackagesWindowState.Tab.history)

            SkippedPackagesView(model: model, openPackageHomepage: openPackageHomepage)
                .tabItem { Text("Skipped (\(model.rememberedSkippedPackageIDs.count))") }
                .tag(PackagesWindowState.Tab.skipped)
        }
        .padding(12)
        .frame(minWidth: 380, maxWidth: 640, minHeight: 300, maxHeight: .infinity)
    }
}
