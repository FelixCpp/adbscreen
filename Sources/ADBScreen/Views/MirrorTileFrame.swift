import AppKit
import SwiftUI

/// Shared chrome for one mirror tile in the grid: a title bar with a
/// disconnect button, and a waiting/error overlay shown until the session
/// has live video.
struct MirrorTileFrame<Content: View>: View {
    let title: String
    let isConnected: Bool
    let statusText: String
    var instructionText: String? = nil
    var errorText: String? = nil
    var footerNote: String? = nil
    var onScreenshot: (() -> Void)? = nil
    var isRecording: Bool = false
    var recordingStartDate: Date? = nil
    var onToggleRecording: (() -> Void)? = nil
    /// scrcpy-equivalent extras (Android only): show-touches, stay-awake,
    /// and a remote screen power toggle, tucked into an overflow menu so
    /// the title bar doesn't get crowded with rarely-used icons.
    var showTouchesEnabled: Bool = false
    var onToggleShowTouches: (() -> Void)? = nil
    var stayAwakeEnabled: Bool = false
    var onToggleStayAwake: (() -> Void)? = nil
    var isScreenOff: Bool = false
    var onToggleScreenPower: (() -> Void)? = nil
    /// Bump this (e.g. a counter) each time a screenshot is captured to
    /// trigger a brief camera-flash overlay.
    var screenshotTrigger: Int = 0
    var onTitleBarDragChanged: ((CGPoint, CGSize) -> Void)? = nil
    var onTitleBarDragEnded: (() -> Void)? = nil
    let onDisconnect: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var flashOpacity: Double = 0
    @State private var recordingPulse = false
    @State private var isExtrasPopoverPresented = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(isConnected ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                    .scaleEffect(isConnected ? 1 : 0.8)
                    .animation(.spring(response: 0.35, dampingFraction: 0.6), value: isConnected)
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                if isConnected, isRecording, let recordingStartDate {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                            .opacity(recordingPulse ? 0.35 : 1)
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: recordingPulse)
                            .onAppear { recordingPulse = true }
                        Text(recordingStartDate, style: .timer)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.9))
                            .monospacedDigit()
                    }
                    .padding(.trailing, 2)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                if isConnected, let onToggleRecording {
                    titleBarButton(
                        systemName: isRecording ? "stop.fill" : "record.circle",
                        help: isRecording ? "Aufnahme stoppen" : "Aufnahme starten",
                        tint: isRecording ? .red : nil,
                        action: onToggleRecording
                    )
                }
                if isConnected, let onScreenshot {
                    titleBarButton(systemName: "camera.fill", help: "Screenshot speichern", action: onScreenshot)
                }
                if isConnected, onToggleShowTouches != nil || onToggleStayAwake != nil || onToggleScreenPower != nil {
                    extrasMenu
                }
                titleBarButton(systemName: "xmark", help: "Trennen", action: onDisconnect)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.75))
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named("mirrorGrid"))
                    .onChanged { onTitleBarDragChanged?($0.location, $0.translation) }
                    .onEnded { _ in onTitleBarDragEnded?() }
            )
            .animation(.easeInOut(duration: 0.25), value: isRecording)

            ZStack {
                Color.black
                content()
                    .opacity(isConnected ? 1 : 0)
                    .scaleEffect(isConnected ? 1 : 1.02)

                if isConnected, isScreenOff {
                    Color.black.opacity(0.9)
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "moon.fill")
                                    .font(.system(size: 28))
                                Text("Bildschirm ausgeschaltet")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundStyle(.white.opacity(0.75))
                        )
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }

                if !isConnected {
                    VStack(spacing: 16) {
                        // Driven by a TimelineView (wall-clock time) rather than
                        // withAnimation/repeatForever: a state-driven repeatForever
                        // animation gets silently frozen whenever an ambient
                        // `.animation(value:)` transaction elsewhere in this same
                        // subtree fires while it's mid-cycle — which is exactly
                        // what happens on "Neu verbinden" (disconnect+connect
                        // fire back-to-back, retriggering the `isConnected`
                        // animation below). Computing the angle from the clock
                        // sidesteps SwiftUI's animation system entirely, so it
                        // can never get stuck.
                        TimelineView(.animation) { context in
                            let t = context.date.timeIntervalSinceReferenceDate
                            let spinAngle = (t.truncatingRemainder(dividingBy: 1.1) / 1.1) * 360
                            let pulse = (sin(t * 2 * .pi / 1.1) + 1) / 2
                            ZStack {
                                Circle()
                                    .stroke(Color.white.opacity(0.12), lineWidth: 2)
                                    .frame(width: 56, height: 56)
                                Circle()
                                    .trim(from: 0, to: 0.28)
                                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                    .frame(width: 56, height: 56)
                                    .rotationEffect(.degrees(spinAngle))
                                Image(systemName: "iphone.gen3")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .scaleEffect(0.94 + pulse * 0.12)
                            }
                        }
                        Text(statusText)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                        if let instructionText {
                            Text(instructionText)
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 28)
                        }
                        if let errorText {
                            Text(errorText)
                                .font(.system(size: 13))
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                        }
                        if let footerNote {
                            Text(footerNote)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }

                Color.white
                    .opacity(flashOpacity)
                    .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.35), value: isConnected)
            .animation(.easeInOut(duration: 0.25), value: isScreenOff)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 6)
        .onChange(of: screenshotTrigger) { _, _ in
            flashOpacity = 0.85
            withAnimation(.easeOut(duration: 0.45)) {
                flashOpacity = 0
            }
        }
    }

    private var extrasMenu: some View {
        titleBarButton(systemName: "slider.horizontal.3", help: "Anzeigeoptionen") {
            isExtrasPopoverPresented.toggle()
        }
        .popover(isPresented: $isExtrasPopoverPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                if let onToggleShowTouches {
                    Toggle(
                        "Touches anzeigen",
                        isOn: Binding(
                            get: { showTouchesEnabled },
                            set: { _ in
                                onToggleShowTouches()
                            }
                        )
                    )
                }
                if let onToggleStayAwake {
                    Toggle(
                        "Bildschirm wach halten",
                        isOn: Binding(
                            get: { stayAwakeEnabled },
                            set: { _ in
                                onToggleStayAwake()
                            }
                        )
                    )
                }
                if let onToggleScreenPower {
                    Button(isScreenOff ? "Bildschirm einschalten" : "Bildschirm ausschalten") {
                        onToggleScreenPower()
                    }
                }
            }
            .padding(10)
        }
    }

    private func titleBarButton(systemName: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint ?? .white.opacity(0.85))
                .frame(width: 26, height: 26)
                .background((tint ?? Color.white).opacity(tint != nil ? 0.18 : 0.12), in: Circle())
        }
        .buttonStyle(TitleBarButtonStyle())
        .help(help)
    }
}

/// Subtle press-down "squish" for the small circular header buttons.
private struct TitleBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.5), value: configuration.isPressed)
    }
}
