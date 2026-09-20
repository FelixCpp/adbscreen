import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        NavigationSplitView(columnVisibility: $appState.sidebarVisibility) {
            SidebarView(appState: appState)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            MirrorGridView(appState: appState)
        }
        .navigationSplitViewStyle(.prominentDetail)
        .frame(minWidth: 1100, minHeight: 700)
    }
}
