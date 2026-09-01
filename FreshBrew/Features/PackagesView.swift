import Combine
import SwiftUI

@MainActor
final class PackagesWindowState: ObservableObject {
    enum Tab: CaseIterable, Hashable {
        case installed
        case history
        case skipped

        var title: String {
            switch self {
            case .installed: "Installed"
            case .history: "History"
            case .skipped: "Skipped"
            }
        }

        var windowTitle: String {
            switch self {
            case .installed: "Installed Packages"
            case .history: "Update History"
            case .skipped: "Skipped Packages"
            }
        }

        func title(skippedPackageCount: Int) -> String {
            self == .skipped ? "\(title) (\(skippedPackageCount))" : title
        }
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
            InstalledPackagesView(
                model: model,
                isActive: windowState.selectedTab == .installed,
                openPackageHomepage: openPackageHomepage
            )
                .tabItem { Text(PackagesWindowState.Tab.installed.title) }
                .tag(PackagesWindowState.Tab.installed)

            HistoryView(model: model, openPackageHomepage: openPackageHomepage)
                .tabItem { Text(PackagesWindowState.Tab.history.title) }
                .tag(PackagesWindowState.Tab.history)

            SkippedPackagesView(model: model, openPackageHomepage: openPackageHomepage)
                .tabItem {
                    Text(PackagesWindowState.Tab.skipped.title(
                        skippedPackageCount: model.rememberedSkippedPackageIDs.count
                    ))
                }
                .tag(PackagesWindowState.Tab.skipped)
        }
        .padding(12)
        .frame(minWidth: 380, maxWidth: 640, minHeight: 300, maxHeight: .infinity)
    }
}
