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
        .pointingHandCursor()
        .onHover { isHovering in
            self.isHovering = isHovering
        }
    }
}
