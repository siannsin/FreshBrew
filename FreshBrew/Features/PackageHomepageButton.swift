import SwiftUI

struct PackageHomepageButton: View {
    let packageName: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(packageName)
                .underline(isHovering)
        }
        .buttonStyle(.plain)
        .help("Open package homepage")
        .pointingHandCursor()
        .onHover { isHovering in
            self.isHovering = isHovering
        }
    }
}
