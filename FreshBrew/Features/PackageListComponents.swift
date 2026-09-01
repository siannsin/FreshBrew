import SwiftUI

enum PackageListMetrics {
    static let horizontalPadding: CGFloat = 16
    static let rowHeight: CGFloat = 35
    static let sectionHeaderHeight: CGFloat = 34
    static let sectionIconSize: CGFloat = 16
    static let actionSize: CGFloat = 24
}

struct PackageSectionHeader: View {
    let title: String
    let count: Int
    let systemImage: String
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(
                        width: PackageListMetrics.sectionIconSize,
                        height: PackageListMetrics.sectionIconSize
                    )

                Text("\(title) (\(count))")
                    .fontWeight(.semibold)

                Spacer(minLength: 8)

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(
                        width: PackageListMetrics.sectionIconSize,
                        height: PackageListMetrics.sectionIconSize
                    )
            }
            .padding(.horizontal, PackageListMetrics.horizontalPadding)
            .frame(maxWidth: .infinity)
            .frame(height: PackageListMetrics.sectionHeaderHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
