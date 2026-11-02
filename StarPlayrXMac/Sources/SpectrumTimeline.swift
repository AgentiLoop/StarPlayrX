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

    private struct Chunk { let channel: String; let start: Date; let sequence: Int; let hop: Double; let duration: Double; let frames: [[Float]] }
    private struct Track { let hop: Double; let first: Int; var frames: [[Float]] }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "StarPlayrX.spectrum", qos: .utility)
    private var segmentDates = [String: Date]()   // live segment file name -> start on the player's 10 s grid
    private var realDates = [String: Date]()      // live segment file name -> real EXT-X-PROGRAM-DATE-TIME
    private var liveChannel = ""
    /// The player dates the stream from the first playlist it loads, counting every segment as its
    /// tagged 10 s, but segments really hold ~9.75 s, so its date drifts ~8 s ahead of the real PDT by
    /// the live edge. Segments are placed on that same 10 s grid so the bars match the player exactly.
    private var anchor: (sequence: Int, date: Date)?
    private var startSlot: Int?   // the segment slot playback started on, in the item's timeline
    private static let nominal = 10.0
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
        if channel != liveChannel { anchor = nil; startSlot = nil }
        if anchor == nil, let first = dates.min(by: { $0.value < $1.value }), let seq = Self.sequence(first.key) {
            anchor = (seq, first.value)
        }
        if let anchor {
            segmentDates = [:]
            for name in dates.keys {
                guard let seq = Self.sequence(name) else { continue }
                segmentDates[name] = anchor.date.addingTimeInterval(Double(seq - anchor.sequence) * Self.nominal)
            }
        }
        realDates = dates
        liveChannel = channel
        live.removeAll { $0.channel != channel }
        lock.unlock()
    }

    /// Server thread hands each segment over before the player gets it; decrypt, decode and analyze here.
    private func segment(_ name: String, _ data: Data, _ key: Data?) {
        if data.isEmpty { return }
        lock.lock()
        let start = segmentDates[name]
        let done = live.contains { $0.start == start }
        lock.unlock()
        guard !done else { return }
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
        guard !frames.isEmpty, let audio = try? AVAudioFile(forReading: file) else { return }
        let duration = Double(audio.length) / audio.processingFormat.sampleRate   // ~9.75 s, not the tagged 10
        lock.lock()
        live.removeAll { $0.start == start }
        live.append(Chunk(channel: Self.channel(name), start: start, sequence: sequence, hop: hop, duration: duration, frames: frames))
        if live.count > 30 { live.removeFirst(live.count - 30) }
        lock.unlock()
    }

    /// Bars for the live stream at the player item's current time. The item places the segment it
    /// starts on at its tagged position (10 s per segment before it), but from there on its clock runs
    /// on the audio itself, ~9.75 s per segment. Assuming 10 s put the bars 0.25 s further behind with
    /// every segment (1 s after 40 s, 2 s after 80 s), so walk the real decoded durations instead.
    func levels(time: Double) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard let anchor, time >= 0 else { return nil }
        let start = startSlot ?? Int(time / Self.nominal)
        startSlot = start
        var slot = start
        var t = time - Double(slot) * Self.nominal
        if t < 0 {   // before where playback started (a seek back): still on the tagged 10 s grid
            slot = Int(time / Self.nominal)
            t = time - Double(slot) * Self.nominal
        }
        var sequence = anchor.sequence + slot
        var lastDuration = 9.75
        for _ in 0..<60 {
            let c = live.first { $0.channel == liveChannel && $0.sequence == sequence }
            let duration = c?.duration ?? lastDuration
            if t < duration {
                guard let c, let last = c.frames.last else { return nil }
                let k = Int(t / c.hop)
                return k < c.frames.count ? c.frames[k] : last
            }
            t -= duration
            lastDuration = duration
            sequence += 1
        }
        return nil
    }

    /// The real on-air time (stream PDT) of the player's current date, which runs ahead of it.
    func realDate(at date: Date) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        for (name, start) in segmentDates {
            let t = date.timeIntervalSince(start)
            guard t >= 0, t < Self.nominal, let real = realDates[name] else { continue }
            return real.addingTimeInterval(t * 0.975)   // a 10 s slot holds ~9.75 s of audio
        }
        return nil
    }

    /// The player starts a new item: it dates the stream afresh from the playlist it loads next.
    func resetLive() {
        lock.lock()
        anchor = nil
        startSlot = nil
        live.removeAll()
        lock.unlock()
    }

    private static func sequence(_ name: String) -> Int? {
        let parts = name.split(separator: "_")
        return parts.count > 2 ? Int(parts[parts.count - 2]) : nil
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
                tracks[file]?.frames += frames
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
    /// One frame every 512 samples (~86 a second at 44.1 kHz), each an FFT of the 1024 around it,
    /// so a 60 fps display always has a fresh frame to show.
    private static let hop = 512

    /// Decodes an AAC file and hands `emit` the bars of every 512 samples, about a second at a time:
    /// (seconds per frame, index of the first frame, frames). `emit` returns false to stop.
    private static func decode(_ url: URL, from seconds: Double = 0,
                               emit: (Double, Int, [[Float]]) -> Bool) {
        guard let file = try? AVAudioFile(forReading: url) else { return }
        let format = file.processingFormat
        let rate = format.sampleRate
        let channels = Int(format.channelCount)
        var index = Int(seconds * rate) / hop
        file.framePosition = AVAudioFramePosition(index * hop)
        let chunk = AVAudioFrameCount(hop * 86)
        guard rate > 0, channels > 0, file.framePosition < file.length,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        let bands = Bands()
        var pending = [Float]()   // samples not yet covered by a full 1024 window, carried into the next chunk
        while (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0,
              let data = buffer.floatChannelData {
            let length = Int(buffer.frameLength)
            var mono = Array(UnsafeBufferPointer(start: data[0], count: length))
            for c in 1..<channels { mono = vDSP.add(mono, UnsafeBufferPointer(start: data[c], count: length)) }
            if channels > 1 { mono = vDSP.multiply(1 / Float(channels), mono) }
            pending += mono
            guard pending.count >= n else { continue }
            let frames = stride(from: 0, through: pending.count - n, by: hop).map { bands.levels(pending[$0..<$0 + n]) }
            pending.removeFirst(frames.count * hop)
            guard emit(Double(hop) / rate, index, frames) else { return }
            index += frames.count
        }
    }

    /// FFT of one 1024-sample block into `Visualizer.bandCount` bar heights (0...1).
    private final class Bands {
        private let fft = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))
        private var window = [Float](repeating: 0, count: SpectrumTimeline.n)

        init() { vDSP_hann_window(&window, vDSP_Length(SpectrumTimeline.n), Int32(vDSP_HANN_NORM)) }
        deinit { if let fft { vDSP_destroy_fftsetup(fft) } }

        func levels(_ block: ArraySlice<Float>) -> [Float] {
            let n = SpectrumTimeline.n
            let half = n / 2
            let windowed = vDSP.multiply(block, window)
            var real = [Float](repeating: 0, count: half)
            var imag = [Float](repeating: 0, count: half)
            var mags = [Float](repeating: 0, count: half)
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    guard let fft, let realp = rp.baseAddress, let imagp = ip.baseAddress else { return }
                    var split = DSPSplitComplex(realp: realp, imagp: imagp)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress?.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(fft, &split, 1, 10, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
                }
            }
            // Log-spaced bands from bin 2 (~90 Hz) up to ~16 kHz (bin 372 at 44.1 kHz). The AAC
            // encoder cuts off most content above that, so a band reaching Nyquist never moved.
            let count = Visualizer.bandCount
            let top: Float = 372
            return (0..<count).map { b in
                let lo = Int(2 * pow(top / 2, Float(b) / Float(count)))
                let hi = max(lo + 1, min(half, Int(2 * pow(top / 2, Float(b + 1) / Float(count)))))
                let peak = mags[lo..<hi].max() ?? 0
                let db = 20 * log10(peak / Float(n) + 1e-9)
                return max(0, min(1, (db + 50) / 50))
            }
        }
    }
}



