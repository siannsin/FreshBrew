import AppKit
import SwiftUI

struct PackageSkipButton: View {
    let isSkipped: Bool
    var isRevealed = false
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @State private var isHovering = false

    private var isActive: Bool {
        isHovering || isFocused
    }

    private var isVisible: Bool {
        isSkipped || isRevealed || isActive
    }

    private var usesAccentColor: Bool {
        isActive || (isRevealed && !isSkipped)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: isSkipped ? "circle.slash.fill" : "circle.slash")
                .foregroundStyle(usesAccentColor ? Color.accentColor : Color.secondary)
                .opacity(isVisible ? 1 : 0)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .help(isSkipped ? "Stop skipping updates" : "Skip updates")
        .accessibilityLabel(isSkipped ? "Stop skipping updates" : "Skip updates")
        .pointingHandCursor()
        .onHover { isHovering in
            self.isHovering = isHovering
        }
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { isHovering in
            (isHovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }
}

extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}
