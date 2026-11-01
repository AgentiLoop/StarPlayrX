import SwiftUI

/// Spectrum of what is playing. The bars are worked out ahead of time from the decoded audio
/// (`SpectrumTimeline`); this reads the frame at the player's position ~30 times a second
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
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
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
        // Rise instantly, fall slowly.
        levels = zip(levels, new).map { old, new in max(new, old * 0.8) }
        // ~30 updates a second: quiet ≈ one colour cycle per 30 s, loud ≈ one per 3 s.
        let energy = Double(new.reduce(0, +) / Float(new.count))
        phase = (phase + 0.001 + energy * 0.02).truncatingRemainder(dividingBy: 1)
        let bass = new.prefix(4).reduce(0, +) / 4
        let kick = bass - bassAverage
        bassAverage = bassAverage * 0.95 + bass * 0.05
        pulse = max(Double(max(0, kick) * 4).clamped, pulse * 0.85)

        // Bar colours blend the old rolling wave (global phase plus a slow wave across the bars)
        // halfway toward a random palette. A strong kick (at most every ~3 s) or a rare random
        // moment throws a new palette; each bar glides there at a pace set by its own band,
        // onsets nudge it, and each bar is softened toward its neighbours so colours flow sideways.
        paletteCooldown -= 1
        if (kick > 0.25 && paletteCooldown <= 0) || Int.random(in: 0..<450) == 0 {
            newPalette()
            paletteCooldown = 90
        }
        let t = phase * 2 * .pi
        let glided = hues.indices.map { i in
            let x = Double(i) / Double(Self.bandCount)
            let wave = phase + x * 0.3 + 0.08 * sin(x * 7 + t * 3)
            let target = wave + 0.5 * Self.shortest(hueTargets[i] - wave)
            let level = Double(new[i])
            let onset = Double(max(0, new[i] - previous[i]))
            return hues[i] + Self.shortest(target - hues[i]) * (0.01 + 0.08 * level) + onset * 0.04
        }
        hues = glided.indices.map { i in
            let left = glided[max(0, i - 1)], right = glided[min(glided.count - 1, i + 1)]
            let h = glided[i] + 0.25 * (Self.shortest(left - glided[i]) + Self.shortest(right - glided[i]))
            return (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
        }

        // Spectral centroid, 0 (bass-heavy) ... 1 (treble-heavy).
        let total = new.reduce(0, +)
        let weighted = new.enumerated().reduce(Float(0)) { $0 + Float($1.offset) * $1.element }
        let centroid = total > 0.01 ? Double(weighted / total) / Double(new.count - 1) : 0.5
        // New random spot on a strong kick, or now and then on its own.
        if kick > 0.15 || Int.random(in: 0..<90) == 0 { wanderTarget = .random(in: -1...1) }
        wander += (wanderTarget - wander) * 0.04
        let target = Swift.min(1, Swift.max(-1, (centroid * 2 - 1) * 1.5 + wander * 0.6))
        blobX += (target - blobX) * 0.08
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

    private func hue(_ x: Double) -> Double { (x.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) }

    var body: some View {
        let bg = ContrastColor.background(scheme)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(viz.levels.indices, id: \.self) { i in
                let level = Double(viz.levels[i])
                let h = viz.hues[i]
                let base = ContrastColor.color(hue: h, saturation: 0.9, against: bg)
                let top = ContrastColor.color(hue: hue(h + 0.06 + 0.1 * level), saturation: 0.75, against: bg, minRatio: 4.5)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(LinearGradient(colors: [base, top], startPoint: .bottom, endPoint: .top))
                    .frame(height: max(2, CGFloat(level) * 28))
                    .shadow(color: top.opacity(0.4 + 0.6 * viz.pulse), radius: 1 + 4 * viz.pulse)
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
        .animation(.linear(duration: 0.05), value: viz.levels)
        .onAppear { viz.start() }
        .onDisappear { viz.stop() }
    }
}
