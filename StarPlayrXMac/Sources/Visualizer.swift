import SwiftUI
import AppKit
import ImageIO

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

    static func color(hue: Double, saturation: Double, against bg: Double, minRatio: Double = 3.5) -> Color {
        let dark = bg < 0.5
        // Dark background: full brightness, then wash toward white. Light: darken.
        for step in 0...20 {
            let k = Double(step) / 20
            let s = dark ? saturation * (1 - 0.7 * k) : saturation
            let b = dark ? 1 : 1 - 0.75 * k
            let (r, g, bl) = rgb(hue, s, b)
            let l = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(bl)
            let ratio = (max(l, bg) + 0.05) / (min(l, bg) + 0.05)
            if ratio >= minRatio || step == 20 { return Color(red: r, green: g, blue: bl) }
        }
        return .primary
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
struct SpectrumView: View {
    @ObservedObject private var viz = Visualizer.shared
    @Environment(\.colorScheme) private var scheme
    /// Luminance of the wallpaper behind the panel (it shows through the translucent material).
    @State private var wallpaper: Double?
    /// Clicking the bars steps the bubbles: full → half strength → off → full. Defaults to soft; each click
    /// fades out one step at a time, so a click always does something visible; remembered.
    @AppStorage("bubbleStage") private var bubbleStage = 1   // UserDefaults; Soft Bubbles until the user picks
    private var bubbleStrength: Double { [0.90, 0.5, 0][bubbleStage % 3] }

    private func hue(_ x: Double) -> Double { (x.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) }

    var body: some View {
        let fixed = ContrastColor.background(scheme)
        // The material mostly hides the wallpaper; let a bright or dark desktop pull the guess part way.
        let bg = wallpaper.map { fixed * 0.7 + $0 * 0.3 } ?? fixed
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(viz.levels.indices, id: \.self) { i in
                let level = Double(viz.levels[i])
                let h = viz.hues[i]
                let base = ContrastColor.color(hue: h, saturation: 0.9, against: fixed)
                let top = ContrastColor.color(hue: hue(h + 0.06 + 0.1 * level), saturation: 0.75, against: fixed, minRatio: 4.5)
                // A glow in the bar's own colour washes out on a light background; there it's the darkest shade
                // of the bar's hue instead, and stronger, so the bars stand off it. The panel is translucent, so a
                // bright wallpaper makes it light in Dark Mode too: decide from the wallpaper, not just the scheme.
                let light = bg >= 0.5 || (wallpaper ?? 0) >= 0.35
                let glow = light ? ContrastColor.color(hue: hue(h + 0.06 + 0.1 * level), saturation: 0.9, against: max(bg, 0.84), minRatio: 14) : top
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(LinearGradient(colors: [base, top], startPoint: .bottom, endPoint: .top))
                    // On a light panel a thin dark edge keeps pale bars from melting into it.
                    .overlay {
                        if light {
                            RoundedRectangle(cornerRadius: 1.5).strokeBorder(.black.opacity(0.25), lineWidth: 0.5)
                        }
                    }
                    .overlay { if bubbleStrength > 0 { LavaBubbles(rise: viz.rise[i], seed: Double(i), color: light ? .black.opacity(0.7) : .white,   // dark bubbles at 70% strength, so they stay soft
                                                  shade: Color(hue: h, saturation: 0.9, brightness: 1))   // the bar's pure colour, not contrast-darkened
                        .opacity(bubbleStrength) } }
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))
                    .frame(height: max(2, CGFloat(level) * 28))
                    .shadow(color: glow.opacity(light ? 0.75 + 0.25 * viz.pulse : 0.4 + 0.6 * viz.pulse), radius: 1 + 4 * viz.pulse)
            }
        }
        .frame(height: 28, alignment: .bottom)
        .background {
            // The "lava": a blurred blob of the colour opposite the middle bar's, swelling on the beat.
            Ellipse()
                .fill(Color(hue: hue(viz.hues[Visualizer.bandCount / 2] + 0.5), saturation: 0.8, brightness: 1))
                .scaleEffect(x: 0.6 + 0.3 * sin(viz.phase * 2 * .pi * 2), y: 0.6 + 0.5 * viz.pulse)
                .offset(x: 80 * viz.blobX)
                .blur(radius: 14)
                .opacity(0.075 + 0.175 * viz.pulse)
        }
        .animation(.linear(duration: 1.0 / 60), value: viz.levels)
        .background(WallpaperProbe(luminance: $wallpaper))
        .contentShape(Rectangle())
        .onTapGesture {
            bubbleStage = (bubbleStage + 1) % 3
            // Names the new stage in a chat bubble whose pointer tip is on the mouse.
            BubblePopup.shared.show(["Bubbles", "Soft Bubbles", "No Bubbles"][bubbleStage], at: NSEvent.mouseLocation)
        }
        .help("Click to change the bubbles: full, soft, off")
        .onAppear { viz.start() }
        .onDisappear { viz.stop() }
    }
}

/// Shows a `ChatBubble` for a moment in its own small floating window, so it is never cropped by the
/// panel's edge. The bottom of the pointer sits exactly on the given screen point.
@MainActor
private final class BubblePopup {
    static let shared = BubblePopup()
    private let pad: CGFloat = 4   // room for the bubble's shadow inside its window
    private var window: NSPanel?
    private var shown = 0

    func show(_ text: String, at point: NSPoint) {
        let host = NSHostingView(rootView: ChatBubble(text: text).padding(pad))
        let size = host.fittingSize
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
        panel.contentView = host
        panel.setFrame(NSRect(x: point.x - size.width / 2, y: point.y - pad, width: size.width, height: size.height), display: true)
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

/// Lava-lamp blobs rising through a bar: 3 or 4 per bar, unevenly spaced, each with its own size.
/// They slowly stretch tall and squash wide as they climb, sway, and fade in at the bottom and out at the top.
private struct LavaBubbles: View {
    let rise: Double
    let seed: Double
    let color: Color
    let shade: Color   // the bar's own colour, for the bubbles that cast a shadow

    var body: some View {
        Canvas { ctx, size in
            guard size.height > 8 else { return }
            let count = 3 + Int(seed) % 2
            // Wall-clock time for the swelling; the canvas redraws every frame while the bubbles rise.
            let now = Date.timeIntervalSinceReferenceDate
            for k in 0..<count {
                // Fixed per bar and slot (so nothing flickers): size, spacing jitter, sway and wobble rate.
                func hash(_ salt: Double) -> Double {
                    abs(sin(seed * 12.9898 + Double(k) * 78.233 + salt) * 43758.5453).truncatingRemainder(dividingBy: 1)
                }
                // Uneven spacing so blobs bunch up and drift apart instead of marching in step.
                let slot = (Double(k) + 0.6 * hash(1)) / Double(count)
                let p = (rise + slot + seed * 0.137).truncatingRemainder(dividingBy: 1)
                // 20...85% of the bar's width, swelling a little as it rises, like warm wax.
                // Each one slowly swells and shrinks (about 60...140%) on its own 3-6 s breath, never in step.
                let period = 3 + 3 * hash(5)
                let breath = 1 + 0.4 * sin(2 * .pi * (now / period + hash(6)))
                let d = min(size.width * (0.2 + 0.65 * hash(0)), size.height * 0.35) * breath
                // Only a slight stretch and squash, so they stay round.
                let wobble = 0.06 * sin(p * 2 * .pi * (1.5 + hash(2)) + Double(k))
                let w = d * (1 - wobble), h = d * (1 + wobble)
                let x = size.width / 2 + size.width * 0.12 * sin(p * (4 + 3 * hash(3)) + seed * 2 + Double(k))
                let y = size.height + h / 2 - (size.height + h) * p           // in from the bottom, out the top
                let fade = min(1, sin(p * .pi) * 2)
                let rect = CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
                // About a third of the bubbles cast a soft shadow down and right, another third glow.
                let look = hash(4)
                if look < 0.33 {
                    // The bar's own colour, solid, 1 pt down and right: a shadow you only just notice.
                    ctx.fill(Path(ellipseIn: rect.offsetBy(dx: 1, dy: 1)), with: .color(shade.opacity(fade)))
                } else if look > 0.67 {
                    let halo = rect.insetBy(dx: -w * 0.4, dy: -h * 0.4)
                    ctx.fill(Path(ellipseIn: halo), with: .radialGradient(
                        Gradient(colors: [Color.white.opacity(0.22 * fade), Color.white.opacity(0)]),
                        center: CGPoint(x: halo.midX, y: halo.midY), startRadius: 0, endRadius: max(halo.width, halo.height) * 0.5))
                }
                // Soft: fades from a gentle centre to nothing at the edge, with no hard rim or highlight.
                ctx.fill(Path(ellipseIn: rect), with: .radialGradient(
                    Gradient(colors: [color.opacity(0.3 * fade), color.opacity(0.14 * fade), color.opacity(0)]),
                    center: CGPoint(x: rect.midX - w * 0.1, y: rect.midY - h * 0.1), startRadius: 0, endRadius: max(w, h) * 0.6))
            }
        }
        .allowsHitTesting(false)
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
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
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
