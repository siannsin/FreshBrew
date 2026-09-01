import SwiftUI

struct SkippedPackagesView: View {
    @ObservedObject var model: MenuBarModel
    let openPackageHomepage: (String, HomebrewPackageKind, URL?) -> Void

    @State private var formulaeExpanded = true
    @State private var casksExpanded = true

    private var formulae: [SkippedPackageItem] {
        skippedPackages(kind: .formula)
    }

    private var casks: [SkippedPackageItem] {
        skippedPackages(kind: .cask)
    }

    var body: some View {
        Group {
            if model.rememberedSkippedPackageIDs.isEmpty {
                ContentUnavailableView(
                    "No skipped packages",
                    systemImage: "checkmark.circle",
                    description: Text("Skipped Homebrew packages will appear here.")
                )
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        if !formulae.isEmpty {
                            packageSection(
                                title: "Formulae",
                                systemImage: "apple.terminal.circle",
                                packages: formulae,
                                isExpanded: $formulaeExpanded
                            )
                        }

                        if !casks.isEmpty {
                            packageSection(
                                title: "Casks",
                                systemImage: "app.grid",
                                packages: casks,
                                isExpanded: $casksExpanded
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func packageSection(
        title: String,
        systemImage: String,
        packages: [SkippedPackageItem],
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(spacing: 0) {
            PackageSectionHeader(
                title: title,
                count: packages.count,
                systemImage: systemImage,
                isExpanded: isExpanded.wrappedValue
            ) {
                isExpanded.wrappedValue.toggle()
            }

            Divider()
                .padding(.horizontal, PackageListMetrics.horizontalPadding)

            if isExpanded.wrappedValue {
                ForEach(packages) { package in
                    HStack {
                        PackageHomepageButton(packageName: package.name) {
                            openPackageHomepage(
                                package.name,
                                package.kind,
                                model.cachedPackageHomepageURL(for: package.id)
                            )
                        }
                        Spacer()
                        PackageSkipButton(isSkipped: true) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                model.forgetSkippedPackage(id: package.id)
                            }
                        }
                    }
                    .padding(.horizontal, PackageListMetrics.horizontalPadding)
                    .frame(maxWidth: .infinity)
                    .frame(height: PackageListMetrics.rowHeight)

                    Divider()
                        .padding(.horizontal, PackageListMetrics.horizontalPadding)
                }
            }
        }
    }

    private func skippedPackages(kind: HomebrewPackageKind) -> [SkippedPackageItem] {
        model.rememberedSkippedPackageIDs
            .compactMap(SkippedPackageItem.init(id:))
            .filter { $0.kind == kind }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct SkippedPackageItem: Identifiable {
    let id: String
    let name: String
    let kind: HomebrewPackageKind

    init?(id: String) {
        let components = id.split(separator: ":", maxSplits: 1)
        guard components.count == 2,
              let kind = HomebrewPackageKind(rawValue: String(components[0])) else {
            return nil
        }
        self.id = id
        name = String(components[1])
        self.kind = kind
    }
}
