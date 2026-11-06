//
//  SpectrumBars.swift
//  StarPlayrKit
//
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  The Mac's equalizer (StarPlayrXMac's SpectrumView) for iPhone, iPad and Apple TV: the same
//  Metal bars from SpectrumRenderer, coloured against the screen's background. Tapping the bars
//  steps the bubbles (BubbleStage, the same setting as the Mac) and names the new stage in a
//  ChatBubble over the tap, like the Mac's click popup.
//

#if canImport(UIKit)
import SwiftUI
import MetalKit

public struct SpectrumBars: View {
    @Environment(\.colorScheme) private var scheme
    /// Inactive with Control Center or Notification Center pulled down: nothing new to see.
    @Environment(\.scenePhase) private var phase
    /// False (paused; PlayerState.barsRunning): the bars stay frozen.
    private let running: Bool
    /// The bars grow out from the middle line both ways (iPhone Duo's side strip, turned on its side).
    private let centred: Bool
    @AppStorage(BubbleStage.key) private var bubbleStage = BubbleStage.defaultStage
    /// The stage label shown after a tap, and where its tail points (nil: top centre of the bars).
    @State private var popup: (text: String, at: CGPoint?)?
    @State private var shown = 0

    public init(running: Bool = true, centred: Bool = false) { self.running = running; self.centred = centred }

    public var body: some View {
        let bg = ContrastColor.background(scheme)
        // The Metal view overhangs the bars on every side so the glow and the blurred blob aren't clipped.
        SpectrumMetalView(fixed: bg, bg: bg, light: bg >= 0.5, bubbles: BubbleStage.strength(bubbleStage),
                          running: running && phase == .active, centred: centred)
            .padding(-CGFloat(SpectrumRenderer.pad))
            .frame(height: CGFloat(SpectrumRenderer.barHeight))
            .contentShape(Rectangle())
            .overlay {
                if let popup {
                    GeometryReader { g in
                        // Bottom of the tail on the tap point, centred on it.
                        ChatBubble(text: popup.text, fontSize: 13)
                            .fixedSize()
                            .alignmentGuide(.leading) { $0.width / 2 - (popup.at?.x ?? g.size.width / 2) }
                            .alignmentGuide(.top) { $0.height - (popup.at?.y ?? 0) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .transition(.opacity)
                }
            }
            #if os(tvOS)
            .onTapGesture { step(at: nil) }
            #else
            .onTapGesture(coordinateSpace: .local) { step(at: $0) }
            #endif
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Equalizer, \(BubbleStage.name(bubbleStage))")
            .accessibilityHint("Changes the bubbles in the bars")
            .onAppear { Visualizer.shared.start() }
            .onDisappear { Visualizer.shared.stop() }
    }

    private func step(at point: CGPoint?) {
        bubbleStage = BubbleStage.next(bubbleStage)
        let text = BubbleStage.name(bubbleStage)
        // The bubble is a passing label VoiceOver never lands on, so say the new stage out loud instead.
        UIAccessibility.post(notification: .announcement, argument: text)
        popup = (text, point)
        shown += 1
        let id = shown
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard shown == id else { return }   // a newer tap keeps its own label up
            withAnimation(.easeOut(duration: 0.3)) { popup = nil }
        }
    }
}


private struct SpectrumMetalView: UIViewRepresentable {
    let fixed: Double, bg: Double, light: Bool, bubbles: Double, running: Bool, centred: Bool

    func makeCoordinator() -> SpectrumRenderer { SpectrumRenderer() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.isOpaque = false
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false   // taps go to the SwiftUI gesture
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        let r = context.coordinator
        (r.fixed, r.bg, r.light, r.bubbles, r.centred) = (fixed, bg, light, bubbles, centred)
        r.setRunning(running, on: view)
    }
}
#endif
