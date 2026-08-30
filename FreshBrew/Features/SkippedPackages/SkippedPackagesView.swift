import AppKit
import SwiftUI

struct SkippedPackagesView: View {
    @ObservedObject var model: MenuBarModel
    let openPackageHomepage: (String, HomebrewPackageKind, URL?) -> Void

    private var skippedPackageIDs: [String] {
        model.rememberedSkippedPackageIDs.sorted()
    }

    var body: some View {
        Group {
            if skippedPackageIDs.isEmpty {
                ContentUnavailableView(
                    "No skipped packages",
                    systemImage: "checkmark.circle",
                    description: Text("Packages you always skip will appear here.")
                )
            } else {
                List(skippedPackageIDs, id: \.self) { packageID in
                    HStack {
                        PackageHomepageButton(
                            packageName: Self.displayName(for: packageID)
                        ) {
                            guard let package = Self.packageIdentity(from: packageID) else {
                                return
                            }
                            openPackageHomepage(
                                package.name,
                                package.kind,
                                model.cachedPackageHomepageURL(for: packageID)
                            )
                        }
                        Spacer()
                        PackageSkipButton(isSkipped: true) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                model.forgetSkippedPackage(id: packageID)
                            }
                        }
                    }
                }
            }
        }
        .frame(
            minWidth: 380,
            maxWidth: .infinity,
            minHeight: 300,
            maxHeight: .infinity
        )
        .navigationTitle("Skipped Packages")
    }

    private static func displayName(for packageID: String) -> String {
        packageID.split(separator: ":", maxSplits: 1).last.map(String.init) ?? packageID
    }

    private static func packageIdentity(
        from packageID: String
    ) -> (name: String, kind: HomebrewPackageKind)? {
        let components = packageID.split(separator: ":", maxSplits: 1)
        guard components.count == 2,
              let kind = HomebrewPackageKind(rawValue: String(components[0])) else {
            return nil
        }
        return (String(components[1]), kind)
    }
}
