//
//  SpectrumBars.swift
//  StarPlayrKit
//
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  The Mac's equalizer (StarPlayrXMac's SpectrumView) for iPhone, iPad and Apple TV: the same
//  Metal bars from SpectrumRenderer, coloured against the screen's background. Tapping the bars
//  steps the bubbles (the same "bubbleStage" setting as the Mac).
//

#if canImport(UIKit)
import SwiftUI
import MetalKit

public struct SpectrumBars: View {
    @Environment(\.colorScheme) private var scheme
    /// Full → half strength → off → full; Soft Bubbles until the user picks.
    @AppStorage("bubbleStage") private var bubbleStage = 1
    private static let stages = ["Bubbles", "Soft Bubbles", "No Bubbles"]

    public init() {}

    public var body: some View {
        let bg = ContrastColor.background(scheme)
        // The Metal view overhangs the bars on every side so the glow and the blurred blob aren't clipped.
        SpectrumMetalView(fixed: bg, bg: bg, light: bg >= 0.5, bubbles: [0.90, 0.5, 0][bubbleStage % 3])
            .padding(-CGFloat(SpectrumRenderer.pad))
            .frame(height: CGFloat(SpectrumRenderer.barHeight))
            .contentShape(Rectangle())
            .onTapGesture { bubbleStage = (bubbleStage + 1) % 3 }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Equalizer, \(Self.stages[bubbleStage % 3])")
            .accessibilityHint("Changes the bubbles in the bars")
            .onAppear { Visualizer.shared.start() }
            .onDisappear { Visualizer.shared.stop() }
    }
}

private struct SpectrumMetalView: UIViewRepresentable {
    let fixed: Double, bg: Double, light: Bool, bubbles: Double

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
        (r.fixed, r.bg, r.light, r.bubbles) = (fixed, bg, light, bubbles)
    }
}
#endif
