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

        GeometryReader { proxy in
            ZStack {
                if items.isEmpty {
                    emptyState
                        .transition(.opacity)
                }

                ScrollView {
                    // A single LazyVGrid — rather than switching between an
                    // `HStack` (≤2 tiles) and a `LazyVGrid` (>2 tiles) —
                    // keeps every tile's identity stable across that
                    // boundary. Swapping between two different container
                    // *types* made SwiftUI tear down and rebuild the entire
                    // previous subtree even though the `ForEach` below keeps
                    // the same `DeviceSelection` ids: each `MirrorTile` (and
                    // the live mirroring connection underneath it) got
                    // destroyed and recreated the moment a 3rd tile made the
                    // layout wrap into a second row, which reconnected every
                    // already-connected device. One container type for
                    // every count avoids that: only the columns and tile
                    // sizing change, so existing tiles simply reflow.
                    LazyVGrid(columns: gridColumns(for: items.count), spacing: 14) {
                        ForEach(items, id: \.self) { selection in
                            sizedTile(selection, itemCount: items.count, availableHeight: proxy.size.height)
                                .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity), removal: .opacity))
                        }
                    }
                    .padding(14)
                }
            }
        }
        .coordinateSpace(name: "mirrorGrid")
        .onPreferenceChange(TileFramePreferenceKey.self) { tileFrames = $0 }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: items)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    /// One device fills the row, two sit side by side (the "customer demo"
    /// case) — both via flexible columns so tiles keep filling the
    /// available height like before. Three or more wrap into an adaptive
    /// grid of aspect-ratio-constrained tiles, same as before.
    private func gridColumns(for count: Int) -> [GridItem] {
        count <= 2
            ? Array(repeating: GridItem(.flexible(), spacing: 14), count: max(count, 1))
            : [GridItem(.adaptive(minimum: 300), spacing: 14)]
    }

    /// Applies the per-item-count sizing on top of `reorderableTile`. Split
    /// out so the `.aspectRatio` modifier can be skipped entirely for ≤2
    /// tiles rather than called with a `nil` ratio: `.aspectRatio(nil, ...)`
    /// is not a no-op — it fits the view to *its own* intrinsic aspect
    /// ratio, which differs per device (or isn't known yet before its video
    /// starts streaming) and was making the two tiles end up unequal
    /// widths instead of split evenly.
    @ViewBuilder
    private func sizedTile(_ selection: AppState.DeviceSelection, itemCount: Int, availableHeight: CGFloat) -> some View {
        if itemCount <= 2 {
            reorderableTile(selection)
                .frame(height: max(availableHeight - 28, 0))
        } else {
            reorderableTile(selection)
                .aspectRatio(0.5, contentMode: .fit)
        }
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
        // The tile being dragged gets a white outline + glow so it reads as
        // "this one is picked up", distinct from the accent-colored outline
        // on whichever tile it's currently hovering over as a drop target.
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white, lineWidth: 3)
                .opacity(draggingSelection == selection ? 1 : 0)
        )
        .shadow(
            color: draggingSelection == selection ? Color.accentColor.opacity(0.6) : .clear,
            radius: draggingSelection == selection ? 22 : 0
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.accentColor, lineWidth: 3)
                .opacity(dropTargetSelection == selection ? 1 : 0)
        )
        // LazyVGrid can otherwise keep neighboring cells in their original
        // drawing order while the dragged cell crosses them. Isolate the
        // complete tile (content + highlight border above) first, then give
        // the active cell a large enough z-index to stay above every other
        // grid item.
        .compositingGroup()
        .zIndex(draggingSelection == selection ? 1000 : 0)
        // `.scaleEffect()` and `.offset()` only transform where a view is
        // *painted* — they don't move the layout frame that an
        // already-attached `.overlay()` aligns itself to. Both have to be
        // the outermost modifiers here (applied to the already-bordered,
        // already-shadowed tile as one composited unit) or the highlight
        // border above ends up a hair too small (sized to the pre-scale
        // frame) and/or pinned at the pre-drag position while the tile
        // itself scales/slides out from under it.
        .scaleEffect(draggingSelection == selection ? 1.02 : 1)
        .offset(draggingSelection == selection ? dragTranslation : .zero)
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
