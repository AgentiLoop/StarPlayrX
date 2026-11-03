//
//  Visualizer.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 10/31/26.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import SwiftUI
import AppKit
import ImageIO
import MetalKit

/// Spectrum of what is playing. The bars are worked out ahead of time from the decoded audio
/// (`SpectrumTimeline`). The Metal view's own frame loop ticks this 30 times a second (no separate
/// timer); it keeps the previous step too, so the GPU tweens bars and bubbles between the two at 60 fps.
@MainActor
final class Visualizer {
    static let shared = Visualizer()
    nonisolated static let bandCount = 24
    /// Seconds between state steps. Each step runs the 60 fps tuned update twice, so speeds are unchanged.
    static let step = 1.0 / 30

    private(set) var levels = [Float](repeating: 0, count: bandCount)
    /// Lava-lamp colour phase (in hue turns). Drifts slowly and speeds up with loudness.
    private(set) var phase: Double = 0
    /// Bass kick above its recent average, 0...1: drives the glow and blob pulse.
    private(set) var pulse: Double = 0
    /// Background blob position, -1 (left) ... 1 (right): follows where the music's energy
    /// sits in the spectrum plus a random wander that jumps on beats.
    private(set) var blobX: Double = 0
    /// Per-bar hue (0...1 turns), driven by the music; see `update`.
    private(set) var hues = (0..<bandCount).map { _ in Double.random(in: 0..<1) }
    /// Lava-lamp bubbles inside each bar: how far they have risen (in bar heights, wraps at 1).
    /// They drift up slowly when the band is quiet and faster when it's loud; a kick gives them a push.
    private(set) var rise = (0..<bandCount).map { _ in Double.random(in: 0..<1) }
    /// The state one step back, for tweening: levels, rise, pulse, blob position.
    private(set) var previous = (levels: [Float](repeating: 0, count: bandCount), rise: [Double](repeating: 0, count: bandCount), pulse: 0.0, blobX: 0.0)
    /// Bar heights of the last four steps, oldest first, for the shader's curve.
    private(set) var history = [[Float]](repeating: [Float](repeating: 0, count: bandCount), count: 4)
    /// Bumped on every step, so each renderer knows when to rebuild its bar colours.
    private(set) var generation = 0
    private var hueTargets = (0..<bandCount).map { _ in Double.random(in: 0..<1) }
    private var paletteCooldown = 0
    private var bassAverage: Float = 0
    private var wander: Double = 0
    private var wanderTarget: Double = 0

    private var running = false
    private var lastStep: CFTimeInterval = 0
    private var viewers = 0   // menu and torn-off window can both show bars

    func start() {
        viewers += 1
        running = true
    }

    func stop() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        running = false
        levels = [Float](repeating: 0, count: Self.bandCount)
        pulse = 0
        previous = (levels, rise, 0, blobX)
        history = [[Float]](repeating: levels, count: 4)
    }

    /// Called by every visible Metal view each frame. Steps the state when 1/30 s has passed and
    /// returns how far the frame is between the previous step and the current one (0...1).
    func tick(now: CFTimeInterval) -> Float {
        if running, now - lastStep >= Self.step - 0.004 {
            previous = (levels, rise, pulse, blobX)
            history.removeFirst()
            // The shader draws a smooth curve through the last four steps, which shows each one two
            // steps (~67 ms) late; reading the audio two steps ahead puts the bars back on the beat.
            // A step spans ~3 analysis frames (11.6 ms each); reading just one picked a random frame and
            // the bars twitched. Average the three, and read a little further ahead for the softer easing below.
            let reads = [0.0, 1.0 / 3, 2.0 / 3].compactMap { Radio.shared.spectrumNow(ahead: (2 + $0) * Self.step + 0.04) }
            let new = reads.isEmpty ? [Float](repeating: 0, count: Self.bandCount)
                : (0..<Self.bandCount).map { i in reads.reduce(0) { $0 + $1[i] } / Float(reads.count) }
            update(new)
            update(new)
            history.append(levels)
            // Keep to the 30 Hz grid, but don't try to catch up after a pause.
            lastStep = now - lastStep < 2 * Self.step ? lastStep + Self.step : now
            generation &+= 1
        }
        return Float(min(1, max(0, (now - lastStep) / Self.step)))
    }

    private func update(_ new: [Float]) {
        guard running else { return }
        let previous = levels
        // Rise fast but over a few frames, fall slowly. At 60 fps an instant rise showed every
        // frame-to-frame wobble of the FFT as jitter; easing in hides it without adding lag you can see.
        // Softer than before (0.55 up, ×0.894 down): bars ease toward each new height instead of jumping.
        levels = zip(levels, new).map { old, new in new > old ? old + (new - old) * 0.35 : max(new, old - (old - new) * 0.18) }
        rise = rise.indices.map { i in
            (rise[i] + 0.0015 + 0.006 * Double(levels[i]) + 0.004 * pulse).truncatingRemainder(dividingBy: 1)
        }
        // 60 updates a second (every step below is half its 30 fps size): quiet ≈ one colour cycle per 30 s, loud ≈ one per 3 s.
        let energy = Double(new.reduce(0, +) / Float(new.count))
        phase = (phase + 0.0005 + energy * 0.01).truncatingRemainder(dividingBy: 1)
        let bass = new.prefix(4).reduce(0, +) / 4
        let kick = bass - bassAverage
        bassAverage = bassAverage * 0.975 + bass * 0.025
        pulse = max(Double(max(0, kick) * 4).clamped, pulse * 0.922)

        // Bar colours blend the old rolling wave (global phase plus a slow wave across the bars)
        // halfway toward a random palette. A strong kick (at most every ~3 s) or a rare random
        // moment throws a new palette; each bar glides there at a pace set by its own band,
        // onsets nudge it, and each bar is softened toward its neighbours so colours flow sideways.
        paletteCooldown -= 1
        if (kick > 0.25 && paletteCooldown <= 0) || Int.random(in: 0..<900) == 0 {
            newPalette()
            paletteCooldown = 180
        }
        let t = phase * 2 * .pi
        let glided = hues.indices.map { i in
            let x = Double(i) / Double(Self.bandCount)
            let wave = phase + x * 0.3 + 0.08 * sin(x * 7 + t * 3)
            let target = wave + 0.5 * Self.shortest(hueTargets[i] - wave)
            let level = Double(new[i])
            let onset = Double(max(0, new[i] - previous[i]))
            return hues[i] + Self.shortest(target - hues[i]) * (0.005 + 0.04 * level) + onset * 0.02
        }
        hues = glided.indices.map { i in
            let left = glided[max(0, i - 1)], right = glided[min(glided.count - 1, i + 1)]
            let h = glided[i] + 0.125 * (Self.shortest(left - glided[i]) + Self.shortest(right - glided[i]))
            return (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
        }

        // Spectral centroid, 0 (bass-heavy) ... 1 (treble-heavy).
        let total = new.reduce(0, +)
        let weighted = new.enumerated().reduce(Float(0)) { $0 + Float($1.offset) * $1.element }
        let centroid = total > 0.01 ? Double(weighted / total) / Double(new.count - 1) : 0.5
        // New random spot on a strong kick, or now and then on its own.
        if kick > 0.15 || Int.random(in: 0..<180) == 0 { wanderTarget = .random(in: -1...1) }
        wander += (wanderTarget - wander) * 0.02
        let target = Swift.min(1, Swift.max(-1, (centroid * 2 - 1) * 1.5 + wander * 0.6))
        blobX += (target - blobX) * 0.04
    }

    /// Hue difference taken the shortest way round the colour wheel, -0.5...0.5.
    private static func shortest(_ d: Double) -> Double {
        var d = d.truncatingRemainder(dividingBy: 1)
        if d > 0.5 { d -= 1 } else if d < -0.5 { d += 1 }
        return d
    }

    /// Random palette in a random scheme, so the row never settles into one predictable cycle.
    private func newPalette() {
        let base = Double.random(in: 0..<1)
        let scheme = Int.random(in: 0..<5)
        let n = Self.bandCount
        hueTargets = (0..<n).map { i in
            let jitter = Double.random(in: -0.04...0.04)
            switch scheme {
            case 0: return base + jitter                                          // analogous
            case 1: return base + (Bool.random() ? 0 : 0.5) + jitter              // complementary
            case 2: return base + Double(Int.random(in: 0..<3)) / 3 + jitter      // triad
            case 3: return base + Double(i) / Double(n) * .random(in: 0.3...1)    // sweep
            default: return .random(in: 0..<1)                                    // confetti
            }
        }
    }
}

/// Picks bar colours that always stand out from the panel: WCAG relative luminance and
/// contrast ratio, lightening (dark mode) or darkening (light mode) a hue only as far as
/// needed to reach `minRatio`, so saturated colours survive wherever they already contrast.
enum ContrastColor {
    /// Approximate luminance of the menu/panel material behind the bars.
    static func background(_ scheme: ColorScheme) -> Double { scheme == .dark ? 0.025 : 0.84 }

    /// The contrast-checked colour as sRGB components (alpha 1), for the Metal shader.
    static func components(hue: Double, saturation: Double, against bg: Double, minRatio: Double = 3.5) -> SIMD4<Float> {
        // Remembered per half-degree of hue: the same few hundred colours come round again and again,
        // and the search below costs up to 21 × 3 pow() calls.
        let key = Key(hue: Int((hue - floor(hue)) * 720), saturation: Int(saturation * 100),
                      bg: Int(bg * 1000), minRatio: Int(minRatio * 10))
        if let hit = cache[key] { return hit }
        if cache.count > 20_000 { cache.removeAll() }
        let c = search(hue: Double(key.hue) / 720, saturation: saturation, against: bg, minRatio: minRatio)
        cache[key] = c
        return c
    }

    private struct Key: Hashable { let hue, saturation, bg, minRatio: Int }
    nonisolated(unsafe) private static var cache = [Key: SIMD4<Float>]()   // only used on the main thread

    private static func search(hue: Double, saturation: Double, against bg: Double, minRatio: Double) -> SIMD4<Float> {
        let dark = bg < 0.5
        // Dark background: full brightness, then wash toward white. Light: darken.
        for step in 0...20 {
            let k = Double(step) / 20
            let s = dark ? saturation * (1 - 0.7 * k) : saturation
            let b = dark ? 1 : 1 - 0.75 * k
            let (r, g, bl) = rgb(hue, s, b)
            let l = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(bl)
            let ratio = (max(l, bg) + 0.05) / (min(l, bg) + 0.05)
            if ratio >= minRatio || step == 20 { return [Float(r), Float(g), Float(bl), 1] }
        }
        return [1, 1, 1, 1]
    }

    /// Plain hue/saturation/brightness as sRGB components (alpha 1).
    static func hsb(_ h: Double, _ s: Double, _ v: Double) -> SIMD4<Float> {
        let (r, g, b) = rgb(h, s, v)
        return [Float(r), Float(g), Float(b), 1]
    }

    private static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func rgb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let h6 = (h - floor(h)) * 6
        let f = h6 - floor(h6)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch Int(h6) % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}

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
    /// Clicking the bars steps the bubbles: full → half strength → off → full. Defaults to soft; each click
    /// fades out one step at a time, so a click always does something visible; remembered.
    @AppStorage("bubbleStage") private var bubbleStage = 1   // UserDefaults; Soft Bubbles until the user picks
    private var bubbleStrength: Double { [0.90, 0.5, 0][bubbleStage % 3] }

    var body: some View {
        let fixed = ContrastColor.background(scheme)
        // The material mostly hides the wallpaper; let a bright or dark desktop pull the guess part way.
        let bg = wallpaper.map { fixed * 0.7 + $0 * 0.3 } ?? fixed
        // A glow in the bar's own colour washes out on a light background; there it's the darkest shade
        // of the bar's hue instead, and stronger, so the bars stand off it. The panel is translucent, so a
        // bright wallpaper makes it light in Dark Mode too: decide from the wallpaper, not just the scheme.
        let light = bg >= 0.5 || (wallpaper ?? 0) >= 0.35
        // The Metal view overhangs the bars on every side so the glow and the blurred blob aren't clipped.
        SpectrumMetalView(fixed: fixed, bg: bg, light: light, bubbles: bubbleStrength)
            .padding(-CGFloat(SpectrumRenderer.pad))
            .frame(height: CGFloat(SpectrumRenderer.barHeight))
            .background(WallpaperProbe(luminance: $wallpaper))
            .contentShape(Rectangle())
            // A double-click is left to the tear-off area around the bars, which rolls the panel up. This
            // empty double-click handler only makes SwiftUI wait out the double-click time, so the single
            // click below doesn't also switch the bubbles.
            .onTapGesture(count: 2) {}
            .onTapGesture {
                bubbleStage = (bubbleStage + 1) % 3
                // Names the new stage in a chat bubble whose pointer tip is on the mouse.
                BubblePopup.shared.show(["Bubbles", "Soft Bubbles", "No Bubbles"][bubbleStage], at: NSEvent.mouseLocation)
            }
            .help(["Bubbles", "Soft Bubbles", "No Bubbles"][bubbleStage % 3])
            .onAppear { viz.start() }
            .onDisappear { viz.stop() }
    }
}

private struct SpectrumMetalView: NSViewRepresentable {
    let fixed: Double, bg: Double, light: Bool, bubbles: Double

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
    }

    /// Clicks go through to the SwiftUI gestures (and the tear-off area) behind it.
    final class PassThroughMTKView: MTKView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private var observers = [NSObjectProtocol]()
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

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
            isPaused = !(window.isVisible && window.occlusionState.contains(.visible))
        }
    }
}

/// Reads the visualizer state each frame and hands it to the shader: colours are worked out here
/// (24 bars, a few contrast checks each), all per-pixel work runs on the GPU.
@MainActor
final class SpectrumRenderer: NSObject, MTKViewDelegate {
    /// Points the Metal view overhangs the bars on each side, for the glow and the blob.
    static let pad: Float = 18
    /// Height of the tallest bar, in points (was 28).
    static let barHeight: Float = 40

    struct Bar { var base, top, glow, shade, misc, curve: SIMD4<Float> }   // misc: level, rise, previous level, previous rise; curve: last four levels
    struct Globals { var view, state, bubble, blob, blobShape, glowStyle: SIMD4<Float> }

    /// No Metal device, or a shader (Spectrum.metal) that fails to load, leaves these nil: the bars
    /// just don't draw, instead of crashing the app.
    let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()
    private lazy var pipeline: MTLRenderPipelineState? = {
        guard let device, let library = device.makeDefaultLibrary() else { return nil }
        do {
            var bands = Int32(Visualizer.bandCount)
            let constants = MTLFunctionConstantValues()
            constants.setConstantValue(&bands, type: .int, index: 0)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "spectrumVertex")
            desc.fragmentFunction = try library.makeFunction(name: "spectrumFragment", constantValues: constants)
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("StarPlayrX spectrum shader failed: \(error)")
            return nil
        }
    }()
    var fixed = 0.025, bg = 0.025, light = false, bubbles = 0.5
    private var bars = [Bar]()
    private var blobColour = SIMD4<Float>(1, 1, 1, 1)
    private var builtGeneration = -1
    private var builtStyle = [Double]()

    private static func hue(_ x: Double) -> Double { (x.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // A hidden, occluded or rolled-up window doesn't hand drawables back, so asking for one would
        // block the main thread for up to a second each frame.
        guard view.bounds.width > 0, view.bounds.height > 0, let window = view.window,
              window.isVisible, window.occlusionState.contains(.visible),
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let pipeline, let commands = queue?.makeCommandBuffer(), let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        let viz = Visualizer.shared
        let f = viz.tick(now: CACurrentMediaTime())
        let style = [fixed, bg, light ? 1 : 0]
        if viz.generation != builtGeneration || style != builtStyle {
            builtGeneration = viz.generation
            builtStyle = style
            // Light panel: a gentler contrast target and full saturation, so darkening stops while the
            // colours are still juicy instead of sinking to olive and navy.
            let (topRatio, baseRatio, topSat, baseSat) = light ? (2.2, 1.9, 0.95, 1.0) : (4.5, 3.5, 0.75, 0.9)
            bars = viz.levels.indices.map { i -> Bar in
                let level = Double(viz.levels[i]), h = viz.hues[i]
                let top = ContrastColor.components(hue: Self.hue(h + 0.06 + 0.1 * level), saturation: topSat, against: fixed, minRatio: topRatio)
                return Bar(base: ContrastColor.components(hue: h, saturation: baseSat, against: fixed, minRatio: baseRatio),
                           top: top,
                           glow: ContrastColor.hsb(Self.hue(h + 0.1 + 0.35 * level), 1, 0.55 + 0.45 * bg),   // lighter background, lighter glow; fully saturated
                           shade: ContrastColor.hsb(h, 0.9, 1),   // the bar's pure colour, not contrast-darkened
                           // The GPU tweens level and bubble rise from the previous step to this one.
                           misc: [Float(level), Float(viz.rise[i]), viz.previous.levels[i], Float(viz.previous.rise[i])],
                           curve: [viz.history[0][i], viz.history[1][i], viz.history[2][i], viz.history[3][i]])
            }
            blobColour = ContrastColor.hsb(Self.hue(viz.hues[Visualizer.bandCount / 2] + 0.5), 0.8, 1)
        }
        // A handful of scalars: tweened here.
        let pulse = viz.previous.pulse + (viz.pulse - viz.previous.pulse) * Double(f)
        let blobX = viz.previous.blobX + (viz.blobX - viz.previous.blobX) * Double(f)
        // The "lava": a blurred blob of the colour opposite the middle bar's, swelling on the beat.
        var blob = blobColour
        blob.w = Float(0.075 + 0.175 * pulse)
        var globals = Globals(
            view: [Float(view.bounds.width) - 2 * Self.pad, Self.barHeight, Float(view.drawableSize.width / view.bounds.width), Self.pad],
            state: [Float(pulse), light ? 1 : 0, Float(bubbles), Float(Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))],
            bubble: light ? [0, 0, 0, 0.7] : [1, 1, 1, 1],   // dark bubbles at 70% strength, so they stay soft
            blob: blob,
            blobShape: [Float(80 * blobX), Float(0.6 + 0.3 * sin(viz.phase * 2 * .pi * 2)), Float(0.6 + 0.5 * pulse), 13],   // last: glow moved 13 pt down
            glowStyle: [Float(light ? 0.75 + 0.25 * pulse : 0.7 + 0.3 * pulse), Float(1 + 4 * pulse), f, 0])
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&globals, length: MemoryLayout<Globals>.stride, index: 0)
        encoder.setFragmentBytes(&bars, length: MemoryLayout<Bar>.stride * bars.count, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}

/// Shows a `ChatBubble` for a moment in its own small floating window, so it is never cropped by the
/// panel's edge. The bottom of the pointer sits exactly on the given screen point.
@MainActor
private final class BubblePopup {
    static let shared = BubblePopup()
    private let pad: CGFloat = 4   // room for the bubble's shadow inside its window
    private var window: NSPanel?
    private var host: NSHostingView<AnyView>?
    private var shown = 0

    func show(_ text: String, at point: NSPoint) {
        // One hosting view, reused. It must not drive the window's size itself (sizingOptions = []):
        // swapping in a new hosting view each click and letting it resize the window threw AppKit's
        // "too many Update Constraints passes" exception, which crashed the app.
        let content = AnyView(ChatBubble(text: text).fixedSize().padding(pad))
        let host = self.host ?? {
            let h = NSHostingView(rootView: content)
            h.sizingOptions = []
            self.host = h
            return h
        }()
        host.rootView = content
        // Measure with a throwaway hosting view: with sizingOptions = [] the live one reports no
        // size, so the window was 0 wide and the bubble ended up off the click.
        let size = NSHostingView(rootView: content).fittingSize
        let panel = window ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.level = .popUpMenu
            p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            window = p
            return p
        }()
        if panel.contentView !== host { panel.contentView = host }
        panel.setFrame(NSRect(x: point.x - size.width / 2, y: point.y - pad, width: size.width, height: size.height), display: false)
        host.frame = NSRect(origin: .zero, size: size)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        shown += 1
        let id = shown
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard shown == id else { return }   // a newer click keeps its own label up
            await NSAnimationContext.runAnimationGroup { $0.duration = 0.3; panel.animator().alphaValue = 0 }
            if shown == id { panel.orderOut(nil) }
        }
    }
}

/// A small speech bubble: a capsule with a tail pointing down.
private struct ChatBubble: View {
    let text: String


    var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .fixedSize()   // never truncated to "…"
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
            Tail().fill(.regularMaterial).frame(width: 8, height: 4)
        }
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .allowsHitTesting(false)
    }

    private struct Tail: Shape {
        func path(in r: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: r.minX, y: r.minY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
                p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
                p.closeSubpath()
            }
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
