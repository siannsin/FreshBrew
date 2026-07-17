import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: MenuBarModel

    var body: some View {
        Group {
            if model.updateHistory.isEmpty {
                ContentUnavailableView(
                    "No Update History",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Completed Homebrew updates will appear here.")
                )
            } else {
                List {
                    ForEach(HistoryGrouping.days(from: model.updateHistory)) { day in
                        Section(HistoryGrouping.dateTitle(for: day.date)) {
                            ForEach(day.entries) { entry in
                                HistoryEntryView(entry: entry)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 300)
        .navigationTitle("Update History")
    }
}

private struct HistoryEntryView: View {
    let entry: UpdateHistoryEntry

    var body: some View {
        let formulae = entry.packages.filter { $0.kind == .formula }
        let casks = entry.packages.filter { $0.kind == .cask }

        VStack(alignment: .leading, spacing: 8) {
            Text(HistoryGrouping.timeTitle(for: entry.timestamp))
                .font(.caption)
                .foregroundStyle(.secondary)

            HistoryPackageSection(
                title: "Formulae",
                packages: formulae
            )
            HistoryPackageSection(
                title: "Casks",
                packages: casks
            )
            .padding(.top, formulae.isEmpty || casks.isEmpty ? 0 : 6)
        }
        .padding(.vertical, 3)
    }
}

private struct HistoryPackageSection: View {
    let title: String
    let packages: [UpdatedPackage]

    var body: some View {
        if !packages.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(packages) { package in
                    HStack(alignment: .firstTextBaseline) {
                        Text(package.name)
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
