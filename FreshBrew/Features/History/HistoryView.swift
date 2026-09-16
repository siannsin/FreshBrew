import Combine
import SwiftUI

@MainActor
private final class HistoryViewState: ObservableObject {
    @Published private(set) var days: [HistoryDay] = []

    init(model: MenuBarModel) {
        model.$updateHistory
            .map { HistoryGrouping.days(from: $0) }
            .removeDuplicates()
            .assign(to: &$days)
    }
}

struct HistoryView: View {
    @StateObject private var state: HistoryViewState
    let openPackageHomepage: (String, String, HomebrewPackageKind, URL?) -> Void

    init(
        model: MenuBarModel,
        openPackageHomepage: @escaping (String, String, HomebrewPackageKind, URL?) -> Void
    ) {
        _state = StateObject(wrappedValue: HistoryViewState(model: model))
        self.openPackageHomepage = openPackageHomepage
    }

    var body: some View {
        Group {
            if state.days.isEmpty {
                ContentUnavailableView(
                    "No update history",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Completed Homebrew updates will appear here.")
                )
            } else {
                List {
                    ForEach(state.days) { day in
                        Section {
                            Text(HistoryGrouping.dateTitle(for: day.date))
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)

                            ForEach(day.entries) { entry in
                                HistoryEntryView(
                                    entry: entry,
                                    openPackageHomepage: openPackageHomepage
                                )
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HistoryEntryView: View {
    let entry: UpdateHistoryEntry
    let openPackageHomepage: (String, String, HomebrewPackageKind, URL?) -> Void

    var body: some View {
        let formulae = entry.packages.filter { $0.kind == .formula }
        let casks = entry.packages.filter { $0.kind == .cask }

        VStack(alignment: .leading, spacing: 8) {
            Text(HistoryGrouping.timeTitle(for: entry.timestamp))
                .font(.caption)
                .foregroundStyle(.secondary)

            HistoryPackageSection(
                title: "Formulae",
                packages: formulae,
                openPackageHomepage: openPackageHomepage
            )
            HistoryPackageSection(
                title: "Casks",
                packages: casks,
                openPackageHomepage: openPackageHomepage
            )
            .padding(.top, formulae.isEmpty || casks.isEmpty ? 0 : 6)
        }
        .padding(.vertical, 3)
    }
}

private struct HistoryPackageSection: View {
    let title: String
    let packages: [UpdatedPackage]
    let openPackageHomepage: (String, String, HomebrewPackageKind, URL?) -> Void

    var body: some View {
        if !packages.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(packages) { package in
                    HStack(alignment: .firstTextBaseline) {
                        PackageHomepageButton(packageName: package.displayName) {
                            openPackageHomepage(
                                package.id,
                                package.name,
                                package.kind,
                                package.homepageURL
                            )
                        }
                        .lineLimit(1)
                        .layoutPriority(1)
                        Spacer(minLength: 16)
                        Text(HomebrewVersionDisplay.compactTransition(for: package))
                            .monospacedDigit()
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(HomebrewVersionDisplay.fullTransition(for: package))
                    }
                }
            }
        }
    }
}
