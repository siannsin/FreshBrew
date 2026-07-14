import SwiftUI

@main
struct FreshBrewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
        } label: {
            Image(systemName: "cup.and.saucer.fill")
                .accessibilityLabel(AppIdentity.displayName)
        }
    }
}
