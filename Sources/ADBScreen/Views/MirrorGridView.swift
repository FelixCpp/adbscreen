import SwiftUI

/// Lays out every connected device's mirror tile at once: one device fills
/// the space, two sit side by side (the "customer demo" case), three or
/// more wrap into an adaptive grid.
struct MirrorGridView: View {
    @ObservedObject var appState: AppState

    /// Currently dragged tile, used to dim its source position and to
    /// highlight whichever tile is being hovered as a drop target — this is
    /// what makes the grid read as a "swap" canvas rather than a plain list.
    @State private var draggingSelection: AppState.DeviceSelection?
    @State private var dropTargetSelection: AppState.DeviceSelection?
    @State private var dragTranslation: CGSize = .zero
    @State private var tileFrames: [AppState.DeviceSelection: CGRect] = [:]

    var body: some View {
        let items = appState.connectedOrder

        Group {
            if items.count <= 2 {
                // A single ForEach keeps each tile's identity stable across
                // the 0↔1↔2 transitions (same `DeviceSelection` id), so
                // SwiftUI animates tile resizing/sliding/fading as one
                // coherent motion instead of swapping the whole layout out
                // from under it. The empty-state placeholder lives in the
                // same container (as an overlay) rather than a separate
                // top-level branch, so going from 0 to 1 devices animates
                // exactly like the existing 1↔2 case instead of just
                // popping in.
                ZStack {
                    if items.isEmpty {
                        emptyState
                            .transition(.opacity)
                    }
                    HStack(spacing: 14) {
                        ForEach(items, id: \.self) { selection in
                            reorderableTile(selection)
                                .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity), removal: .opacity))
                        }
                    }
                    .padding(14)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                        ForEach(items, id: \.self) { selection in
                            reorderableTile(selection)
                                .aspectRatio(0.5, contentMode: .fit)
                                .transition(.scale(scale: 0.92).combined(with: .opacity))
                        }
                    }
                    .padding(14)
                }
                .transition(.opacity)
            }
        }
        .coordinateSpace(name: "mirrorGrid")
        .onPreferenceChange(TileFramePreferenceKey.self) { tileFrames = $0 }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: items)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Keine Geräte verbunden")
                .font(.system(size: 22, weight: .semibold))
            Text("Klicke links bei einem Gerät auf „Verbinden“, um es hier anzuzeigen.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            if !appState.adbAvailable {
                Text("adb wurde nicht gefunden. Installiere es mit: brew install android-platform-tools")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reorderableTile(_ selection: AppState.DeviceSelection) -> some View {
        MirrorTile(
            selection: selection,
            appState: appState,
            onTitleBarDragChanged: { updateDrag(of: selection, at: $0, translation: $1) },
            onTitleBarDragEnded: finishDrag
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TileFramePreferenceKey.self,
                    value: [selection: proxy.frame(in: .named("mirrorGrid"))]
                )
            }
        )
        .offset(draggingSelection == selection ? dragTranslation : .zero)
        .scaleEffect(draggingSelection == selection ? 1.02 : 1)
        // LazyVGrid can otherwise keep neighboring cells in their original
        // drawing order while the dragged cell crosses them. Isolate the
        // complete tile first, then give the active cell a large enough
        // z-index to stay above every other grid item.
        .compositingGroup()
        .zIndex(draggingSelection == selection ? 1000 : 0)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.accentColor, lineWidth: 3)
                .opacity(dropTargetSelection == selection ? 1 : 0)
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: dragTranslation)
        .animation(.easeInOut(duration: 0.15), value: draggingSelection)
        .animation(.easeInOut(duration: 0.15), value: dropTargetSelection)
    }

    private func updateDrag(
        of source: AppState.DeviceSelection,
        at location: CGPoint,
        translation: CGSize
    ) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            draggingSelection = source
            dragTranslation = translation
            dropTargetSelection = tileFrames.first(where: {
                $0.key != source && $0.value.contains(location)
            })?.key
        }
    }

    private func finishDrag() {
        let source = draggingSelection
        let target = dropTargetSelection
        let animation = Animation.spring(response: 0.35, dampingFraction: 0.75)

        guard let source, let target else {
            withAnimation(animation) {
                draggingSelection = nil
                dropTargetSelection = nil
                dragTranslation = .zero
            }
            return
        }

        // Perform the reorder in the *same* animated transaction as the
        // return-flight (translation → .zero) instead of clearing
        // `draggingSelection` first: that used to drop the dragged tile's
        // zIndex back to 0 a beat before `swapTiles` reordered the array,
        // so it briefly rendered underneath the tile it was dropped on
        // before the two visibly swapped places. Keeping `draggingSelection`
        // (and thus the elevated zIndex) set until this whole motion has
        // settled makes it one continuous, on-top motion.
        withAnimation(animation) {
            dropTargetSelection = nil
            dragTranslation = .zero
            appState.swapTiles(source, target)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if draggingSelection == source {
                draggingSelection = nil
            }
        }
    }
}

private struct TileFramePreferenceKey: PreferenceKey {
    static let defaultValue: [AppState.DeviceSelection: CGRect] = [:]

    static func reduce(
        value: inout [AppState.DeviceSelection: CGRect],
        nextValue: () -> [AppState.DeviceSelection: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
