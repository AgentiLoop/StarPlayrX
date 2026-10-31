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
        // Rise instantly, fall slowly.
        levels = zip(levels, new).map { old, new in max(new, old * 0.8) }
        // ~30 updates a second: quiet ≈ one colour cycle per 30 s, loud ≈ one per 3 s.
        let energy = Double(new.reduce(0, +) / Float(new.count))
        phase = (phase + 0.001 + energy * 0.02).truncatingRemainder(dividingBy: 1)
        let bass = new.prefix(4).reduce(0, +) / 4
        let kick = bass - bassAverage
        bassAverage = bassAverage * 0.95 + bass * 0.05
        pulse = max(Double(max(0, kick) * 4).clamped, pulse * 0.85)

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
}

private extension Double {
    var clamped: Double { Swift.min(1, Swift.max(0, self)) }
}

/// Spectrum bars that flow through colours like a lava lamp, paced by the music:
/// louder music moves the colours faster, bass kicks make the bars glow and a soft blob
/// of colour swell behind them.
struct SpectrumView: View {
    @ObservedObject private var viz = Visualizer.shared

    private func hue(_ x: Double) -> Double { (x.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) }

    /// Base hue for a bar: the global phase plus a slow wave rolling across the bars, so
    /// colours drift and blend sideways instead of the whole row changing at once.
    private func barHue(_ i: Int) -> Double {
        let t = viz.phase * 2 * .pi
        let x = Double(i) / Double(Visualizer.bandCount)
        return hue(viz.phase + x * 0.3 + 0.08 * sin(x * 7 + t * 3))
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(viz.levels.indices, id: \.self) { i in
                let level = Double(viz.levels[i])
                let h = barHue(i)
                let top = Color(hue: hue(h + 0.12), saturation: 0.8, brightness: 0.7 + 0.3 * level)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(LinearGradient(colors: [Color(hue: h, saturation: 0.9, brightness: 0.85), top],
                                         startPoint: .bottom, endPoint: .top))
                    .frame(height: max(2, CGFloat(level) * 28))
                    .shadow(color: top.opacity(0.4 + 0.6 * viz.pulse), radius: 1 + 4 * viz.pulse)
            }
        }
        .frame(height: 28, alignment: .bottom)
        .background {
            // The "lava": a blurred blob of the complementary colour that swells on the beat.
            Ellipse()
                .fill(Color(hue: hue(viz.phase + 0.5), saturation: 0.8, brightness: 1))
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
