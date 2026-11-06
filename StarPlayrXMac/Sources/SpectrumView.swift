//
//  SpectrumView.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 10/31/26.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import SwiftUI
import MetalKit
import ImageIO
import StarPlayrKit

/// Spectrum bars whose colours follow the music: each bar drifts at the pace of its own band,
/// onsets push it along, and bass kicks throw a fresh random palette. Every colour is checked
/// for contrast against the panel. Kicks also make the bars glow and a soft blob swell behind.
/// Everything (blob, glows, bars, bubbles) is drawn by one Metal fragment shader; SwiftUI only
/// re-evaluates this view when the scheme, wallpaper or bubble setting changes, not every frame.
struct SpectrumView: View {
    private let viz = Visualizer.shared
    @Environment(\.colorScheme) private var scheme
    /// Luminance of the wallpaper behind the panel (it shows through the translucent material).
    @State private var wallpaper: Double?
    /// Clicking the bars steps the bubbles (BubbleStage, shared with iOS/tvOS); remembered.
    @AppStorage(BubbleStage.key) private var bubbleStage = BubbleStage.defaultStage
    /// False while paused (PlayerState.barsRunning, shared with iOS): the bars stay frozen.
    var running = true

    var body: some View {
        let fixed = ContrastColor.background(scheme)
        // The material mostly hides the wallpaper; let a bright or dark desktop pull the guess part way.
        let bg = wallpaper.map { fixed * 0.7 + $0 * 0.3 } ?? fixed
        // A glow in the bar's own colour washes out on a light background; there it's the darkest shade
        // of the bar's hue instead, and stronger, so the bars stand off it. The panel is translucent, so a
        // bright wallpaper makes it light in Dark Mode too: decide from the wallpaper, not just the scheme.
        let light = bg >= 0.5 || (wallpaper ?? 0) >= 0.35
        // The Metal view overhangs the bars on every side so the glow and the blurred blob aren't clipped.
        SpectrumMetalView(fixed: fixed, bg: bg, light: light, bubbles: BubbleStage.strength(bubbleStage), running: running)
            .padding(-CGFloat(SpectrumRenderer.pad))
            .frame(height: CGFloat(SpectrumRenderer.barHeight))
            .background(WallpaperProbe(luminance: $wallpaper))
            .contentShape(Rectangle())
            // A double-click is left to the tear-off area around the bars, which rolls the panel up. This
            // empty double-click handler only makes SwiftUI wait out the double-click time, so the single
            // click below doesn't also switch the bubbles.
            .onTapGesture(count: 2) {}
            .onTapGesture {
                bubbleStage = BubbleStage.next(bubbleStage)
                // Names the new stage in a chat bubble whose pointer tip is on the mouse.
                BubblePopup.shared.show(BubbleStage.name(bubbleStage), at: NSEvent.mouseLocation)
            }
            // One element with a name: without it VoiceOver lands on an unlabeled Metal view.
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Equalizer, \(BubbleStage.name(bubbleStage))")
            .accessibilityHint("Changes the bubbles in the bars")
            .onAppear { viz.start() }
            .onDisappear { viz.stop() }
    }
}

private struct SpectrumMetalView: NSViewRepresentable {
    let fixed: Double, bg: Double, light: Bool, bubbles: Double, running: Bool

    func makeCoordinator() -> SpectrumRenderer { SpectrumRenderer() }

    func makeNSView(context: Context) -> MTKView {
        let view = PassThroughMTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.layer?.isOpaque = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        let r = context.coordinator
        (r.fixed, r.bg, r.light, r.bubbles) = (fixed, bg, light, bubbles)
        (view as? PassThroughMTKView)?.running = running
    }

    /// Clicks go through to the SwiftUI gestures (and the tear-off area) behind it.
    final class PassThroughMTKView: MTKView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private var observers = [NSObjectProtocol]()
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
        /// False while playback is paused: the loop stops too, leaving the bars frozen.
        var running = true { didSet { if running != oldValue { updatePaused() } } }

        /// Stops the 60 fps loop entirely while the window is hidden or covered, instead of waking
        /// up every frame only to find there is nothing to draw on.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { isPaused = true; return }
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updatePaused() }
                })
            updatePaused()
        }

        private func updatePaused() {
            guard let window else { return }
            let visible = window.isVisible && window.occlusionState.contains(.visible)
            (delegate as? SpectrumRenderer)?.setRunning(running && visible, on: self)
        }
    }
}

/// Measures the desktop picture under the window hosting the bars: on show, and whenever the
/// window moves or the Space changes. Reads the wallpaper file, so no screen-recording permission.
private struct WallpaperProbe: NSViewRepresentable {
    @Binding var luminance: Double?

    func makeNSView(context: Context) -> ProbeView { ProbeView { lum in DispatchQueue.main.async { luminance = lum } } }
    func updateNSView(_ view: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        private let report: (Double?) -> Void
        private var observers = [NSObjectProtocol]()
        init(report: @escaping (Double?) -> Void) { self.report = report; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.measure() })
            }
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.measure() })
            measure()
        }

        private func measure() {
            guard let window, let screen = window.screen,
                  let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return report(nil) }
            let rect = window.convertToScreen(convert(bounds, to: nil))
            let frame = screen.frame
            let report = report
            DispatchQueue.global(qos: .utility).async {
                report(Self.luminance(of: url, in: rect, screen: frame))
            }
        }

        /// Average luminance of the part of the wallpaper (scaled to fill the screen) under `rect`.
        private static func luminance(of url: URL, in rect: CGRect, screen: CGRect) -> Double? {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary)
            else { return nil }
            let iw = Double(image.width), ih = Double(image.height)
            let scale = max(iw / screen.width, ih / screen.height)          // fill: crop the overflow, centred
            let ox = (iw - screen.width * scale) / 2, oy = (ih - screen.height * scale) / 2
            // Screen y goes up from the bottom; image y goes down from the top.
            let x = ox + (rect.minX - screen.minX) * scale
            let y = oy + (screen.maxY - rect.maxY) * scale
            let crop = CGRect(x: x, y: y, width: max(1, rect.width * scale), height: max(1, rect.height * scale)).integral
            guard let part = image.cropping(to: crop) else { return nil }
            guard let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .medium
            ctx.draw(part, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            guard let data = ctx.data else { return nil }
            let px = data.assumingMemoryBound(to: UInt8.self)
            func lin(_ c: UInt8) -> Double { let v = Double(c) / 255; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(px[0]) + 0.7152 * lin(px[1]) + 0.0722 * lin(px[2])
        }
    }
}
