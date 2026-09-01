import SwiftUI

struct InstalledPackagesView: View {
    @ObservedObject var model: MenuBarModel
    let isActive: Bool
    let openPackageHomepage: (String, HomebrewPackageKind, URL?) -> Void

    @State private var searchText = ""
    @State private var formulaeExpanded = true
    @State private var casksExpanded = true
    @FocusState private var isSearchFocused: Bool

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var formulae: [InstalledPackage] {
        InstalledPackagePresentation.packages(
            from: model.installedPackages,
            kind: .formula,
            query: searchText
        )
    }

    private var casks: [InstalledPackage] {
        InstalledPackagePresentation.packages(
            from: model.installedPackages,
            kind: .cask,
            query: searchText
        )
    }

    private var isLoading: Bool {
        model.installedPackagesLoadState == .loading
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
                .padding(.horizontal, PackageListMetrics.horizontalPadding)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        isSearchFocused = false
                    }
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            isSearchFocused = false
            loadInventoryIfNeeded()
        }
        .onChange(of: isActive) {
            loadInventoryIfNeeded()
        }
        .onChange(of: model.activity) {
            loadInventoryIfNeeded()
        }
        .onExitCommand {
            isSearchFocused = false
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            TextField("Search packages", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .focused($isSearchFocused)
                .overlay(alignment: .trailing) {
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            isSearchFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .padding(.trailing, 6)
                        .help("Clear search")
                    }
                }

            Button {
                isSearchFocused = false
                Task { await model.loadInstalledPackages() }
            } label: {
                Group {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 16, height: 16)
            }
            .disabled(model.isRunning)
            .help("Refresh installed packages")
        }
        .padding(.horizontal, PackageListMetrics.horizontalPadding)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        if model.installedPackages.isEmpty {
            switch model.installedPackagesLoadState {
            case .notLoaded, .loading:
                loadingView
            case let .failed(message):
                loadFailureView(message)
            case .loaded:
                emptyInventoryView
            }
        } else if case let .failed(message) = model.installedPackagesLoadState {
            VStack(spacing: 0) {
                refreshFailureBanner(message)
                packageList
            }
        } else {
            packageList
        }
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading installed packages…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadFailureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn’t load packages", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                Task { await model.loadInstalledPackages() }
            }
        }
    }

    private var emptyInventoryView: some View {
        ContentUnavailableView(
            "No installed packages",
            systemImage: "shippingbox",
            description: Text("Installed Homebrew packages will appear here.")
        )
    }

    private func refreshFailureBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Refresh failed: \(message)")
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Try Again") {
                Task { await model.loadInstalledPackages() }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var packageList: some View {
        if isSearching, formulae.isEmpty, casks.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: 0)
                            .id(PackageListAnchor.top)

                        if !isSearching || !formulae.isEmpty {
                            packageSection(
                                title: "Formulae",
                                systemImage: "apple.terminal.circle",
                                packages: formulae,
                                isExpanded: expansionBinding(
                                    stored: $formulaeExpanded,
                                    hasMatches: !formulae.isEmpty
                                )
                            )
                        }

                        if !isSearching || !casks.isEmpty {
                            packageSection(
                                title: "Casks",
                                systemImage: "app.grid",
                                packages: casks,
                                isExpanded: expansionBinding(
                                    stored: $casksExpanded,
                                    hasMatches: !casks.isEmpty
                                )
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: searchText) {
                    proxy.scrollTo(PackageListAnchor.top, anchor: .top)
                }
            }
        }
    }

    private func packageSection(
        title: String,
        systemImage: String,
        packages: [InstalledPackage],
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(spacing: 0) {
            PackageSectionHeader(
                title: title,
                count: packages.count,
                systemImage: systemImage,
                isExpanded: isExpanded.wrappedValue
            ) {
                isSearchFocused = false
                isExpanded.wrappedValue.toggle()
            }

            Divider()
                .padding(.horizontal, PackageListMetrics.horizontalPadding)

            if isExpanded.wrappedValue {
                ForEach(Array(packages.enumerated()), id: \.element.id) { index, package in
                    packageRow(package)

                    if index < packages.count - 1 {
                        Divider()
                            .padding(.horizontal, PackageListMetrics.horizontalPadding)
                    }
                }
            }
        }
    }

    private func packageRow(_ package: InstalledPackage) -> some View {
        let isSkipped = model.rememberedSkippedPackageIDs.contains(package.id)

        return InstalledPackageRow(package: package, isSkipped: isSkipped) {
            isSearchFocused = false
            openPackageHomepage(
                package.name,
                package.kind,
                package.homepageURL
            )
        } onToggleSkip: {
            isSearchFocused = false
            if isSkipped {
                model.forgetSkippedPackage(id: package.id)
            } else {
                model.rememberSkip(package)
            }
        }
    }

    private enum PackageListAnchor {
        static let top = "installed-packages-list-top"
    }

    private func expansionBinding(
        stored: Binding<Bool>,
        hasMatches: Bool
    ) -> Binding<Bool> {
        Binding {
            isSearching ? hasMatches : stored.wrappedValue
        } set: { isExpanded in
            guard !isSearching else { return }
            stored.wrappedValue = isExpanded
        }
    }

    private func loadInventoryIfNeeded() {
        guard isActive,
              model.activity == .idle,
              (model.installedPackagesLoadState == .notLoaded
                || model.installedPackagesNeedRefresh) else { return }
        // Switching tabs should not cancel an inventory read already in progress.
        Task { await model.loadInstalledPackages() }
    }
}

private struct InstalledPackageRow: View {
    let package: InstalledPackage
    let isSkipped: Bool
    let onOpenHomepage: () -> Void
    let onToggleSkip: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            if package.homepageURL != nil {
                PackageHomepageButton(
                    packageName: package.name,
                    action: onOpenHomepage
                )
            } else {
                Text(package.name)
            }

            PackageSkipButton(
                isSkipped: isSkipped,
                isRevealed: isHovered,
                action: onToggleSkip
            )

            Spacer(minLength: 12)

            Text(HomebrewVersionDisplay.compact(
                package.installedVersion,
                kind: package.kind
            ))
            .font(.body)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: 112, alignment: .trailing)
        }
        .padding(.horizontal, PackageListMetrics.horizontalPadding)
        .frame(maxWidth: .infinity, minHeight: PackageListMetrics.rowHeight)
        .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering in
            isHovered = isHovering
        }
        .onDisappear {
            isHovered = false
        }
    }
}
