import SwiftUI

struct ContentView: View {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        NavigationSplitView(columnVisibility: $appState.sidebarVisibility) {
            SidebarView(appState: appState)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            MirrorGridView(appState: appState)
        }
        .navigationSplitViewStyle(.prominentDetail)
        .frame(minWidth: 1100, minHeight: 700)
        // `initial: true` also opens it once on first launch, replacing the
        // old `.sheet(isPresented:)` — see ADBScreenApp for why this is a
        // separate window rather than a sheet.
        .onChange(of: appState.showOnboarding, initial: true) { _, show in
            if show {
                openWindow(id: "onboarding")
            } else {
                dismissWindow(id: "onboarding")
            }
        }
    }
}
