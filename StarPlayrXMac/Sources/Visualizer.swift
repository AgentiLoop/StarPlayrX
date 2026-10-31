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
    static let bandCount = 24

    @Published private(set) var levels = [Float](repeating: 0, count: bandCount)

    private var tap: AnyObject?
    private var retry: Task<Void, Never>?

    func start() {
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
        retry?.cancel()
        retry = nil
        tap = nil
        levels = [Float](repeating: 0, count: Self.bandCount)
    }

    private func update(_ new: [Float]) {
        guard tap != nil else { return }
        // Rise instantly, fall slowly.
        levels = zip(levels, new).map { old, new in max(new, old * 0.8) }
    }
}

struct SpectrumView: View {
    @ObservedObject private var viz = Visualizer.shared

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(viz.levels.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(LinearGradient(colors: [.accentColor, .purple], startPoint: .bottom, endPoint: .top))
                    .frame(height: max(2, CGFloat(viz.levels[i]) * 28))
            }
        }
        .frame(height: 28, alignment: .bottom)
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
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
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
