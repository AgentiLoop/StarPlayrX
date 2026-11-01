import Foundation
import AVFoundation
import Accelerate
import StarPlayrRadioKit

/// Bar heights worked out ahead of time, while the audio is decoded before it plays: live segments
/// as the local server hands them to the player, Xtra tracks as soon as they are downloaded.
/// Every 1024 samples get one frame, stamped with its place in the stream, so the bars are read
/// at the player's exact position: no recording permission, and they can't fall behind the music.
final class SpectrumTimeline: @unchecked Sendable {
    static let shared = SpectrumTimeline()

    private struct Chunk { let channel: String; let start: Date; let hop: Double; let frames: [[Float]] }
    private struct Track { let hop: Double; let first: Int; var frames: [[Float]] }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "StarPlayrX.spectrum", qos: .utility)
    private var segmentDates = [String: Date]()   // live segment file name -> EXT-X-PROGRAM-DATE-TIME
    private var liveChannel = ""
    private var live = [Chunk]()
    private var tracks = [URL: Track]()

    /// Hooks into the local server; call before it starts.
    func observeServer() {
        livePlaylistObserver = { [unowned self] in playlist($0) }
        liveSegmentObserver = { [unowned self] name, data, key in queue.async { self.segment(name, data, key) } }
    }

    // MARK: Live

    private func playlist(_ text: String) {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let tag = "#EXT-X-PROGRAM-DATE-TIME:"
        var dates = [String: Date]()
        var date: Date?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix(tag) {
                date = f.date(from: String(line.dropFirst(tag.count)))
            } else if !line.hasPrefix("#"), let d = date, let name = line.split(separator: "/").last {
                dates[String(name)] = d
                date = nil
            }
        }
        guard let channel = dates.keys.first.map(Self.channel) else { return }
        lock.lock()
        segmentDates = dates
        liveChannel = channel
        live.removeAll { $0.channel != channel }
        lock.unlock()
    }

    /// Server thread hands each segment over before the player gets it; decrypt, decode and analyze here.
    private func segment(_ name: String, _ data: Data, _ key: Data?) {
        lock.lock()
        let start = segmentDates[name]
        lock.unlock()
        // Live segments have no explicit IV: HLS uses the media sequence number, the second-last field of the name.
        let parts = name.split(separator: "_")
        guard let start, let key, parts.count > 2, let sequence = Int(parts[parts.count - 2]),
              let plain = aes128Decrypt(data, key: key, iv: Data(sequenceIV: sequence)) else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("StarPlayrX-\(name)")
        guard (try? stripID3(plain).write(to: file)) != nil else { return }
        defer { try? FileManager.default.removeItem(at: file) }
        var hop = 0.0
        var frames = [[Float]]()
        Self.decode(file) { h, _, f in hop = h; frames += f; return true }
        guard !frames.isEmpty else { return }
        lock.lock()
        live.removeAll { $0.start == start }
        live.append(Chunk(channel: Self.channel(name), start: start, hop: hop, frames: frames))
        if live.count > 30 { live.removeFirst(live.count - 30) }
        lock.unlock()
    }

    /// Bars for the live stream at the player's current date (AVPlayerItem.currentDate()).
    func levels(at date: Date) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        for c in live where c.channel == liveChannel {
            let t = date.timeIntervalSince(c.start)
            guard t >= 0 else { continue }
            let k = Int(t / c.hop)
            if k < c.frames.count { return c.frames[k] }
        }
        return nil
    }

    private static func channel(_ name: String) -> String { String(name.split(separator: "_").first ?? "") }

    // MARK: Xtra

    /// Analyzes a downloaded track from `seconds` on, publishing about a second at a time so the
    /// start is ready almost at once.
    func analyze(track file: URL, from seconds: Double = 0) {
        queue.async { [self] in
            Self.decode(file, from: seconds) { hop, index, frames in
                lock.lock()
                defer { lock.unlock() }
                if tracks[file] == nil, index == Int(seconds / hop) {
                    tracks[file] = Track(hop: hop, first: index, frames: [])
                }
                guard tracks[file] != nil else { return false }   // forgotten meanwhile
                tracks[file]!.frames += frames
                return true
            }
        }
    }

    func levels(track file: URL, at seconds: Double) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard let t = tracks[file], seconds >= 0 else { return nil }
        let k = Int(seconds / t.hop) - t.first
        return k >= 0 && k < t.frames.count ? t.frames[k] : nil
    }

    func forget(track file: URL) {
        lock.lock()
        tracks[file] = nil
        lock.unlock()
    }

    func forgetTracks() {
        lock.lock()
        tracks.removeAll()
        lock.unlock()
    }

    // MARK: Analysis

    private static let n = 1024

    /// Decodes an AAC file and hands `emit` the bars of every 1024 samples, about a second at a time:
    /// (seconds per frame, index of the first frame, frames). `emit` returns false to stop.
    private static func decode(_ url: URL, from seconds: Double = 0,
                               emit: (Double, Int, [[Float]]) -> Bool) {
        guard let file = try? AVAudioFile(forReading: url) else { return }
        let format = file.processingFormat
        let rate = format.sampleRate
        let channels = Int(format.channelCount)
        var index = Int(seconds * rate) / n
        file.framePosition = AVAudioFramePosition(index * n)
        let chunk = AVAudioFrameCount(n * 43)
        guard rate > 0, channels > 0, file.framePosition < file.length,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        let bands = Bands()
        while (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0,
              let data = buffer.floatChannelData {
            let length = Int(buffer.frameLength)
            var mono = Array(UnsafeBufferPointer(start: data[0], count: length))
            for c in 1..<channels { mono = vDSP.add(mono, UnsafeBufferPointer(start: data[c], count: length)) }
            if channels > 1 { mono = vDSP.multiply(1 / Float(channels), mono) }
            let frames = stride(from: 0, through: length - n, by: n).map { bands.levels(mono[$0..<$0 + n]) }
            guard emit(Double(n) / rate, index, frames) else { return }
            index += frames.count
        }
    }

    /// FFT of one 1024-sample block into `Visualizer.bandCount` bar heights (0...1).
    private final class Bands {
        private let fft = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
        private var window = [Float](repeating: 0, count: SpectrumTimeline.n)

        init() { vDSP_hann_window(&window, vDSP_Length(SpectrumTimeline.n), Int32(vDSP_HANN_NORM)) }
        deinit { vDSP_destroy_fftsetup(fft) }

        func levels(_ block: ArraySlice<Float>) -> [Float] {
            let n = SpectrumTimeline.n
            let half = n / 2
            let windowed = vDSP.multiply(block, window)
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
            // Log-spaced bands from bin 2 (~90 Hz) up to Nyquist.
            let count = Visualizer.bandCount
            return (0..<count).map { b in
                let lo = Int(2 * pow(Float(half / 2), Float(b) / Float(count)))
                let hi = max(lo + 1, min(half, Int(2 * pow(Float(half / 2), Float(b + 1) / Float(count)))))
                let peak = mags[lo..<hi].max() ?? 0
                let db = 20 * log10(peak / Float(n) + 1e-9)
                return max(0, min(1, (db + 50) / 50))
            }
        }
    }
}
