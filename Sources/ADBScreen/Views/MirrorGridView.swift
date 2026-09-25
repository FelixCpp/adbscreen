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

    /// Shared with `tileSize`/`tilePosition`/`gridContentSize` below so the
    /// fullscreen frame computed directly in `body` lines up with theirs.
    private let tilePadding: CGFloat = 14

    var body: some View {
        // Every connected device stays in the `ForEach` at all times, even
        // while one is focused — see the per-tile `isFocused`/`isDimmed`
        // handling below. Earlier this filtered `items` down to just the
        // focused selection, which removed every other tile from the
        // `ForEach` and reinserted it later at a brand-new position once
        // focus cleared. Since the focused tile's own grow/shrink animation
        // runs across the same ~0.4s as that reinsertion, the two visually
        // crossed paths — the growing/shrinking tile's edge sweeping right
        // through the other tile's title bar as it popped back in — which
        // read as tiles and icons "jumping" mid-transition. Keeping every
        // tile mounted at its normal grid slot the whole time and merely
        // toggling opacity/hit-testing for the non-focused ones means
        // nothing ever has to reappear at a new position — it just fades
        // in place, out of the way, while only the focused tile's frame
        // animates between its grid slot and the fullscreen one.
        let items = appState.connectedOrder
        let focused = appState.focusedSelection

        GeometryReader { proxy in
            ZStack {
                if items.isEmpty {
                    emptyState
                        .transition(.opacity)
                }

                ScrollView {
                    // A single container type for every tile count — rather
                    // than switching between an `HStack` (≤2 tiles) and a
                    // grid (>2 tiles) — keeps every tile's identity stable
                    // across that boundary. Swapping between two different
                    // container *types* made SwiftUI tear down and rebuild
                    // the entire previous subtree even though the `ForEach`
                    // below keeps the same `DeviceSelection` ids: each
                    // `MirrorTile` (and the live mirroring connection
                    // underneath it) got destroyed and recreated the moment
                    // a 3rd tile made the layout wrap into a second row,
                    // which reconnected every already-connected device. One
                    // container type for every count avoids that: only the
                    // per-tile size and position change, so existing tiles
                    // simply reflow.
                    //
                    // Crucially, that also rules out an `if/else` anywhere
                    // in this per-tile view builder (even just to pick which
                    // *modifier* to apply): a `@ViewBuilder if/else` is the
                    // exact same trap — the two branches are different
                    // concrete types, so SwiftUI tears down and rebuilds
                    // every tile the moment the active branch flips (e.g.
                    // disconnecting a device crosses the ≤2/>2 boundary).
                    // `tileSize(for:available:)` below does all the ≤2-vs->2
                    // branching in plain Swift on `CGFloat`s instead, so
                    // every tile always gets the exact same
                    // `.frame(width:height:)` call — only the numbers differ.
                    //
                    // This is a plain `ZStack` with manually computed
                    // `.position()`s, not a `LazyVGrid` — `.zIndex()` is
                    // documented to work reliably only between siblings of a
                    // real (non-lazy) stack. Inside `LazyVGrid`/`LazyHStack`/
                    // etc. SwiftUI is free to composite each cell into its
                    // own layer in an order it chooses, so the dragged
                    // tile's elevated zIndex could still end up painted
                    // *under* a neighboring tile mid-drag. A plain `ZStack`
                    // is a real stacking context, so ordering by `.zIndex()`
                    // is guaranteed instead of best-effort.
                    let size = tileSize(itemCount: items.count, available: proxy.size)
                    let contentSize = gridContentSize(itemCount: items.count, tileSize: size, available: proxy.size)
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(items.enumerated()), id: \.element) { index, selection in
                            let isFocused = focused == selection
                            // Hidden behind the focused tile rather than
                            // removed from the ForEach — see the comment on
                            // `items` above for why that matters.
                            let isDimmed = focused != nil && !isFocused
                            reorderableTile(selection, isFocused: isFocused)
                                .frame(
                                    width: isFocused ? proxy.size.width - tilePadding * 2 : size.width,
                                    height: isFocused ? proxy.size.height - tilePadding * 2 : size.height
                                )
                                .position(
                                    isFocused
                                        ? CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                                        : tilePosition(for: index, itemCount: items.count, tileSize: size)
                                )
                                .opacity(isDimmed ? 0 : 1)
                                .allowsHitTesting(!isDimmed)
                                .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity), removal: .opacity))
                        }
                    }
                    .frame(width: contentSize.width, height: contentSize.height)
                }
            }
        }
        .coordinateSpace(name: "mirrorGrid")
        .onPreferenceChange(TileFramePreferenceKey.self) { tileFrames = $0 }
        // dampingFraction 1 (critically damped) instead of the old 0.8: an
        // underdamped spring overshoots a large move and settles back —
        // visible as a wobble. Critical damping still eases in smoothly but
        // never overshoots the target position/size. `items` covers real
        // connect/disconnect/reorder changes; `focused` is separate because
        // toggling it no longer touches `items` at all (see the comment
        // above) — every tile stays mounted and only its frame/opacity
        // changes.
        .animation(.spring(response: 0.4, dampingFraction: 1), value: items)
        .animation(.spring(response: 0.4, dampingFraction: 1), value: focused)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        // Esc leaves the fullscreen focus view and returns to the grid.
        .onExitCommand { appState.focusedSelection = nil }
    }

    /// One device fills the row, two sit side by side (the "customer demo"
    /// case), three or more wrap into a grid.
    private func columnCount(for itemCount: Int) -> Int {
        itemCount <= 2 ? max(itemCount, 1) : max(2, Int(ceil(sqrt(Double(itemCount)))))
    }

    /// Every tile's width/height, computed the same way regardless of count
    /// so the call site never has to branch on it (see the note above). For
    /// ≤2 devices this fills the available height edge to edge, same as the
    /// old `HStack`; for 3+ it keeps a portrait phone-like 1:2 aspect ratio
    /// so tiles wrap into a legible grid instead of stretching thin.
    private func tileSize(itemCount: Int, available: CGSize) -> CGSize {
        guard itemCount > 0 else { return .zero }
        let spacing: CGFloat = 14
        let padding = tilePadding
        let columns = columnCount(for: itemCount)
        let width = max((available.width - padding * 2 - spacing * CGFloat(columns - 1)) / CGFloat(columns), 160)

        if itemCount <= 2 {
            return CGSize(width: width, height: max(available.height - padding * 2, 0))
        }
        return CGSize(width: width, height: width * 2)
    }

    /// Center point of the tile at `index` (row-major, wrapping at
    /// `columnCount`), in the same "mirrorGrid" coordinate space the drag
    /// gesture and `TileFramePreferenceKey` already use.
    private func tilePosition(for index: Int, itemCount: Int, tileSize: CGSize) -> CGPoint {
        let spacing: CGFloat = 14
        let padding = tilePadding
        let columns = columnCount(for: itemCount)
        let row = index / columns
        let col = index % columns
        let x = padding + tileSize.width / 2 + CGFloat(col) * (tileSize.width + spacing)
        let y = padding + tileSize.height / 2 + CGFloat(row) * (tileSize.height + spacing)
        return CGPoint(x: x, y: y)
    }

    /// The `ZStack`'s own explicit size — needed because `.position()`
    /// doesn't contribute to a ZStack's intrinsic size the way normal
    /// in-flow layout would, so without this the ScrollView wouldn't know
    /// how much content there is to scroll.
    private func gridContentSize(itemCount: Int, tileSize: CGSize, available: CGSize) -> CGSize {
        guard itemCount > 0 else { return .zero }
        let spacing: CGFloat = 14
        let padding = tilePadding
        let columns = columnCount(for: itemCount)
        let rows = Int(ceil(Double(itemCount) / Double(columns)))
        let width = max(available.width, CGFloat(columns) * tileSize.width + CGFloat(columns - 1) * spacing + padding * 2)
        let height = CGFloat(rows) * tileSize.height + CGFloat(rows - 1) * spacing + padding * 2
        return CGSize(width: width, height: height)
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

    private func reorderableTile(_ selection: AppState.DeviceSelection, isFocused: Bool) -> some View {
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
        .zIndex(isFocused ? 1000 : (draggingSelection == selection ? 999 : 0))
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
        // Reordering doesn't mean anything with only one tile visible, and
        // every non-focused tile still reports a frame via
        // `TileFramePreferenceKey` even while hidden (opacity doesn't affect
        // layout), which could otherwise register as a bogus drop target.
        guard appState.focusedSelection == nil else { return }
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
