import SwiftUI
import AppKit
import ImageIO
import MetalKit

/// Spectrum of what is playing. The bars are worked out ahead of time from the decoded audio
/// (`SpectrumTimeline`); this reads the frame at the player's position 60 times a second
/// and adds the colour, glow and blob motion.
@MainActor
final class Visualizer: ObservableObject {
    static let shared = Visualizer()
    nonisolated static let bandCount = 24

    @Published private(set) var levels = [Float](repeating: 0, count: bandCount)
    /// Lava-lamp colour phase (in hue turns). Drifts slowly and speeds up with loudness.
    @Published private(set) var phase: Double = 0
    /// Bass kick above its recent average, 0...1: drives the glow and blob pulse.
    @Published private(set) var pulse: Double = 0
    /// Background blob position, -1 (left) ... 1 (right): follows where the music's energy
    /// sits in the spectrum plus a random wander that jumps on beats.
    @Published private(set) var blobX: Double = 0
    /// Per-bar hue (0...1 turns), driven by the music; see `update`.
    @Published private(set) var hues = (0..<bandCount).map { _ in Double.random(in: 0..<1) }
    /// Lava-lamp bubbles inside each bar: how far they have risen (in bar heights, wraps at 1).
    /// They drift up slowly when the band is quiet and faster when it's loud; a kick gives them a push.
    @Published private(set) var rise = (0..<bandCount).map { _ in Double.random(in: 0..<1) }
    private var hueTargets = (0..<bandCount).map { _ in Double.random(in: 0..<1) }
    private var paletteCooldown = 0
    private var bassAverage: Float = 0
    private var wander: Double = 0
    private var wanderTarget: Double = 0

    private var timer: Timer?
    private var viewers = 0   // menu and torn-off window can both show bars

    func start() {
        viewers += 1
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            Task { @MainActor in
                let v = Visualizer.shared
                v.update(Radio.shared.spectrumNow ?? [Float](repeating: 0, count: Self.bandCount))
            }
        }
        RunLoop.main.add(timer, forMode: .common)   // keeps ticking while the menu is tracking
        self.timer = timer
    }

    func stop() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        timer?.invalidate()
        timer = nil
        levels = [Float](repeating: 0, count: Self.bandCount)
        pulse = 0
    }

    private func update(_ new: [Float]) {
        guard timer != nil else { return }
        let previous = levels
        // Rise fast but over a few frames, fall slowly. At 60 fps an instant rise showed every
        // frame-to-frame wobble of the FFT as jitter; easing in hides it without adding lag you can see.
        levels = zip(levels, new).map { old, new in new > old ? old + (new - old) * 0.55 : max(new, old * 0.894) }
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

private extension Double {
    var clamped: Double { Swift.min(1, Swift.max(0, self)) }
}

/// Picks bar colours that always stand out from the panel: WCAG relative luminance and
/// contrast ratio, lightening (dark mode) or darkening (light mode) a hue only as far as
/// needed to reach `minRatio`, so saturated colours survive wherever they already contrast.
enum ContrastColor {
    /// Approximate luminance of the menu/panel material behind the bars.
    static func background(_ scheme: ColorScheme) -> Double { scheme == .dark ? 0.025 : 0.84 }

    /// The contrast-checked colour as sRGB components (alpha 1), for the Metal shader.
    static func components(hue: Double, saturation: Double, against bg: Double, minRatio: Double = 3.5) -> SIMD4<Float> {
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
            .frame(height: 28)
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
    }
}

/// Reads the visualizer state each frame and hands it to the shader: colours are worked out here
/// (24 bars, a few contrast checks each), all per-pixel work runs on the GPU.
@MainActor
final class SpectrumRenderer: NSObject, MTKViewDelegate {
    /// Points the Metal view overhangs the bars on each side, for the glow and the blob.
    static let pad: Float = 18

    struct Bar { var base, top, glow, shade, misc: SIMD4<Float> }   // misc: level, rise
    struct Globals { var view, state, bubble, blob, blobShape, glowStyle: SIMD4<Float> }

    let device = MTLCreateSystemDefaultDevice()!
    private lazy var queue = device.makeCommandQueue()!
    private lazy var pipeline: MTLRenderPipelineState = {
        let library = try! device.makeLibrary(source: Self.shader, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "spectrumVertex")
        desc.fragmentFunction = library.makeFunction(name: "spectrumFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try! device.makeRenderPipelineState(descriptor: desc)
    }()
    var fixed = 0.025, bg = 0.025, light = false, bubbles = 0.5

    private static func hue(_ x: Double) -> Double { (x.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard view.bounds.width > 0, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(), let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        let viz = Visualizer.shared
        let pulse = viz.pulse
        var bars = viz.levels.indices.map { i -> Bar in
            let level = Double(viz.levels[i]), h = viz.hues[i]
            let top = ContrastColor.components(hue: Self.hue(h + 0.06 + 0.1 * level), saturation: 0.75, against: fixed, minRatio: 4.5)
            return Bar(base: ContrastColor.components(hue: h, saturation: 0.9, against: fixed),
                       top: top,
                       glow: ContrastColor.hsb(Self.hue(h + 0.06 + 0.2 * level), 1, 0.3 + 0.6 * bg),   // lighter background, lighter glow; fully saturated
                       shade: ContrastColor.hsb(h, 0.9, 1),   // the bar's pure colour, not contrast-darkened
                       misc: [Float(level), Float(viz.rise[i]), 0, 0])
        }
        // The "lava": a blurred blob of the colour opposite the middle bar's, swelling on the beat.
        var blob = ContrastColor.hsb(Self.hue(viz.hues[Visualizer.bandCount / 2] + 0.5), 0.8, 1)
        blob.w = Float(0.075 + 0.175 * pulse)
        var globals = Globals(
            view: [Float(view.bounds.width) - 2 * Self.pad, 28, Float(view.drawableSize.width / view.bounds.width), Self.pad],
            state: [Float(pulse), light ? 1 : 0, Float(bubbles), Float(Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))],
            bubble: light ? [0, 0, 0, 0.7] : [1, 1, 1, 1],   // dark bubbles at 70% strength, so they stay soft
            blob: blob,
            blobShape: [Float(80 * viz.blobX), Float(0.6 + 0.3 * sin(viz.phase * 2 * .pi * 2)), Float(0.6 + 0.5 * pulse), 0],
            glowStyle: [Float(light ? 0.75 + 0.25 * pulse : 0.7 + 0.3 * pulse), Float(1 + 4 * pulse), 0, 0])
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&globals, length: MemoryLayout<Globals>.stride, index: 0)
        encoder.setFragmentBytes(&bars, length: MemoryLayout<Bar>.stride * bars.count, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    #define BANDS \(Visualizer.bandCount)

    struct Bar { float4 base, top, glow, shade, misc; };
    struct Globals {
        float4 view;       // bars width, bars height (pt), pixels per point, overhang (pt)
        float4 state;      // pulse, light panel, bubble strength, seconds
        float4 bubble;     // bubble colour, alpha
        float4 blob;       // blob colour, opacity
        float4 blobShape;  // x offset (pt), x scale, y scale
        float4 glowStyle;  // glow opacity, glow radius (pt)
    };

    vertex float4 spectrumVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);   // one triangle covering the view
        return float4(p * 2 - 1, 0, 1);
    }

    static float roundedRect(float2 p, float2 centre, float2 hs, float r) {
        float2 q = abs(p - centre) - (hs - r);
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    static float ellipse(float2 p, float2 r) {
        float k0 = length(p / r), k1 = length(p / (r * r));
        return k1 > 0 ? k0 * (k0 - 1) / k1 : -min(r.x, r.y);
    }

    static float cover(float sd, float px) { return saturate(0.5 - sd / px); }

    static float4 over(float4 dst, float3 rgb, float a) { return float4(rgb * a, a) + dst * (1 - a); }

    // Fixed per bar and slot (so nothing flickers): size, spacing jitter, sway and wobble rate.
    static float hash(float seed, float k, float salt) {
        return fract(abs(sin(seed * 12.9898 + k * 78.233 + salt) * 43758.5453));
    }

    // Lava-lamp blobs rising through a bar: 3 or 4 per bar, unevenly spaced, each with its own size.
    // They slowly stretch and squash as they climb, sway, breathe, and fade in at the bottom and out at the top.
    static float4 bubbles(float4 dst, float2 lp, float2 size, int i, Bar b, constant Globals &g, float px) {
        float seed = i, strength = g.state.z, now = g.state.w;
        int count = 3 + i % 2;
        for (int k = 0; k < count; k++) {
            float fk = k;
            float slot = (fk + 0.6 * hash(seed, fk, 1)) / count;
            float p = fract(b.misc.y + slot + seed * 0.137);
            float period = 3 + 3 * hash(seed, fk, 5);
            float breath = 1 + 0.4 * sin(2 * M_PI_F * (now / period + hash(seed, fk, 6)));
            float d = min(size.x * (0.2 + 0.65 * hash(seed, fk, 0)), size.y * 0.35) * breath;
            float wobble = 0.06 * sin(p * 2 * M_PI_F * (1.5 + hash(seed, fk, 2)) + fk);
            float2 r = float2(d * (1 - wobble), d * (1 + wobble)) / 2;
            float2 c = float2(size.x / 2 + size.x * 0.12 * sin(p * (4 + 3 * hash(seed, fk, 3)) + seed * 2 + fk),
                              size.y + r.y - (size.y + 2 * r.y) * p);   // in from the bottom, out the top
            float fade = min(1.0, sin(p * M_PI_F) * 2) * strength;
            float look = hash(seed, fk, 4);
            if (look < 0.33) {
                // The bar's own colour, solid, 1 pt down and right: a shadow you only just notice.
                dst = over(dst, b.shade.rgb, fade * cover(ellipse(lp - c - 1, r), px));
            } else if (look > 0.67) {
                float2 hr = r * 1.8;
                float glow = 1 - saturate(length(lp - c) / max(hr.x, hr.y));
                dst = over(dst, float3(1), 0.22 * fade * glow * cover(ellipse(lp - c, hr), px));
            }
            // Soft: fades from a gentle centre to nothing at the edge, with no hard rim or highlight.
            float t = length(lp - (c - 0.2 * r)) / (1.2 * max(r.x, r.y));
            float a = t < 0.5 ? mix(0.3, 0.14, t / 0.5) : mix(0.14, 0.0, saturate((t - 0.5) / 0.5));
            dst = over(dst, g.bubble.rgb, a * g.bubble.a * fade * cover(ellipse(lp - c, r), px));
        }
        return dst;
    }

    fragment float4 spectrumFragment(float4 pos [[position]], constant Globals &g [[buffer(0)]],
                                     constant Bar *bars [[buffer(1)]]) {
        float W = g.view.x, H = g.view.y, px = 1 / g.view.z;
        float2 p = pos.xy * px - g.view.w;   // points, from the bars' top-left
        float4 out = 0;

        // Blurred blob behind the bars.
        float2 br = max(float2(W / 2 * g.blobShape.y, H / 2 * g.blobShape.z), 0.5);
        float bsd = ellipse(p - float2(W / 2 + g.blobShape.x, H / 2), br);
        out = over(out, g.blob.rgb, g.blob.a * (1 - smoothstep(-14.0, 14.0, bsd)));

        float bw = (W - 2 * (BANDS - 1)) / BANDS;
        float sigma = max(g.glowStyle.y * 0.5, 0.5);
        for (int i = 0; i < BANDS; i++) {
            Bar b = bars[i];
            float hb = max(2.0, b.misc.x * H);
            float2 hs = float2(bw, hb) / 2;
            float2 centre = float2(i * (bw + 2) + hs.x, H - hs.y);
            float sd = roundedRect(p, centre, hs, 1.5);
            if (sd > 3 * sigma + 1) continue;
            float d = max(sd, 0.0);
            out = over(out, b.glow.rgb, g.glowStyle.x * exp(-d * d / (2 * sigma * sigma)));
            float c = cover(sd, px);
            if (c <= 0) continue;
            float2 lp = p - (centre - hs);
            float4 bar = float4(mix(b.base.rgb, b.top.rgb, saturate(1 - lp.y / hb)), 1);
            // On a light panel a thin dark edge keeps pale bars from melting into it.
            if (g.state.y > 0.5 && sd > -0.5) bar = over(bar, float3(0), 0.25);
            if (g.state.z > 0 && hb > 8) bar = bubbles(bar, lp, float2(bw, hb), i, b, g, px);
            out = bar * c + out * (1 - c);
        }
        return out;
    }
    """
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
