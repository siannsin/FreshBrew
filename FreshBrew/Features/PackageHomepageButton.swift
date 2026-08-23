import AppKit
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
        .onHover { isHovering in
            self.isHovering = isHovering
            (isHovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .onDisappear {
            if isHovering {
                NSCursor.arrow.set()
            }
        }
    }
}
