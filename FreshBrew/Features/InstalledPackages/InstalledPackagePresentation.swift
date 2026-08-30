import Foundation

enum InstalledPackagePresentation {
    static func packages(
        from packages: [InstalledPackage],
        kind: HomebrewPackageKind,
        query: String
    ) -> [InstalledPackage] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        return packages
            .filter { package in
                guard package.kind == kind else { return false }
                guard !normalizedQuery.isEmpty else { return true }
                return package.name.localizedCaseInsensitiveContains(normalizedQuery)
            }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
}
