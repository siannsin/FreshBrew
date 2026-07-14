import AppKit
import SwiftUI

struct MenuBarView: View {
    var body: some View {
        Text("FreshBrew is ready")
            .foregroundStyle(.secondary)

        Divider()

        Button("Quit FreshBrew") {
            NSApplication.shared.terminate(nil)
        }
    }
}
