import SwiftUI
import CoreAudio
import AudioToolbox
import Accelerate

/// Spectrum of the app's own audio output. AVPlayer exposes no samples for HLS streams,
/// so this taps the StarPlayrX process with a Core Audio process tap (macOS 14.2+)
/// and turns each 1024-sample block into `bandCount` bar heights (0...1).
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

    private var tap: AnyObject?
    private var retry: Task<Void, Never>?
    private var viewers = 0   // menu and torn-off window can both show bars

    func start() {
        viewers += 1
        guard #available(macOS 14.2, *), tap == nil, retry == nil else { return }
        // The process only gets a Core Audio object once it has played audio, so keep trying.
        retry = Task {
            while !Task.isCancelled {
                if let t = ProcessTap(onLevels: { levels in
                    Task { @MainActor in Visualizer.shared.update(levels) }
                }) {
                    tap = t
                    break
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            retry = nil
        }
    }

    func stop() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        retry?.cancel()
        retry = nil
        tap = nil
        levels = [Float](repeating: 0, count: Self.bandCount)
        pulse = 0
    }

    private func update(_ new: [Float]) {
        guard tap != nil else { return }
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

        // Bar colours: a strong kick (at most every ~1.5 s) or a rare random moment throws a
        // brand-new palette; each bar then glides to its new hue at a speed set by its own band,
        // and sudden rises in a band (an onset) shove that bar's hue along on their own.
        paletteCooldown -= 1
        if (kick > 0.2 && paletteCooldown <= 0) || Int.random(in: 0..<300) == 0 {
            newPalette()
            paletteCooldown = 45
        }
        hues = hues.indices.map { i in
            let level = Double(new[i])
            let onset = Double(max(0, new[i] - previous[i]))
            var delta = (hueTargets[i] - hues[i]).truncatingRemainder(dividingBy: 1)
            if delta > 0.5 { delta -= 1 } else if delta < -0.5 { delta += 1 }   // shortest way round
            let h = hues[i] + delta * (0.02 + 0.25 * level) + onset * 0.15
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


@available(macOS 14.2, *)
private final class ProcessTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "StarPlayrX.tap", qos: .userInitiated)

    private let n = 1024
    private let fft = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
    private var window: [Float]
    private var pending = [Float]()
    private var lastSent = DispatchTime.now()
    private let onLevels: ([Float]) -> Void

    init?(onLevels: @escaping ([Float]) -> Void) {
        self.onLevels = onLevels
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        guard let process = Self.ownProcessObject(), let outputUID = Self.defaultOutputUID() else { return nil }

        let desc = CATapDescription(stereoMixdownOfProcesses: [process])
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { return nil }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "StarPlayrX Visualizer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]]
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID) == noErr else {
            teardown()
            return nil
        }
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { [weak self] _, input, _, _, _ in
            self?.receive(input)
        }
        guard status == noErr, AudioDeviceStart(deviceID, procID) == noErr else {
            teardown()
            return nil
        }
    }

    deinit {
        teardown()
        vDSP_destroy_fftsetup(fft)
    }

    private func teardown() {
        if deviceID != kAudioObjectUnknown {
            AudioDeviceStop(deviceID, procID)
            if let procID { AudioDeviceDestroyIOProcID(deviceID, procID) }
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Tap audio is 32-bit float; mix whatever channels arrive down to mono.
    private func receive(_ input: UnsafePointer<AudioBufferList>) {
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            let samples = data.assumingMemoryBound(to: Float.self)
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += samples[f * channels + c] }
                pending.append(sum / Float(channels))
            }
            break
        }
        while pending.count >= n {
            let block = Array(pending.prefix(n))
            pending.removeFirst(n)
            // ~30 updates a second is plenty for the bars.
            guard DispatchTime.now().uptimeNanoseconds - lastSent.uptimeNanoseconds > 33_000_000 else { continue }
            lastSent = .now()
            onLevels(bands(block))
        }
    }

    private func bands(_ block: [Float]) -> [Float] {
        let half = n / 2
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(block, 1, window, 1, &windowed, 1, vDSP_Length(n))
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, 10, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        // Log-spaced bands from bin 2 (~90 Hz at 48 kHz) up to Nyquist.
        let count = Visualizer.bandCount
        return (0..<count).map { b in
            let lo = Int(2 * pow(Float(half / 2), Float(b) / Float(count)))
            let hi = max(lo + 1, min(half, Int(2 * pow(Float(half / 2), Float(b + 1) / Float(count)))))
            let peak = mags[lo..<hi].max() ?? 0
            let db = 20 * log10(peak / Float(n) + 1e-9)
            return max(0, min(1, (db + 50) / 50))
        }
    }

    private static func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}
