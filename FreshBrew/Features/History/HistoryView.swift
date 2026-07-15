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
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(HistoryGrouping.timeTitle(for: entry.timestamp))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    ForEach(entry.packages) { package in
                                        HStack {
                                            Text(package.name)
                                            Spacer()
                                            Text("\(package.previousVersion) → \(package.installedVersion)")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(.vertical, 3)
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
