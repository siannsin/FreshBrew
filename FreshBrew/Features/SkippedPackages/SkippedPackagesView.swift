import SwiftUI

struct SkippedPackagesView: View {
    @ObservedObject var model: MenuBarModel

    var body: some View {
        Group {
            if model.rememberedSkippedPackageIDs.isEmpty {
                ContentUnavailableView(
                    "No Skipped Packages",
                    systemImage: "checkmark.circle",
                    description: Text("Packages you always skip will appear here.")
                )
            } else {
                List(model.rememberedSkippedPackageIDs.sorted(), id: \.self) { packageID in
                    HStack {
                        Text(Self.displayName(for: packageID))
                        Spacer()
                        Button("Stop Skipping") {
                            model.forgetSkippedPackage(id: packageID)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 280)
        .navigationTitle("Skipped Packages")
    }

    private static func displayName(for packageID: String) -> String {
        packageID.split(separator: ":", maxSplits: 1).last.map(String.init) ?? packageID
    }
}
