//
//  SpectrumTimeline.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 11/1/26.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import Foundation
import AVFoundation
import Accelerate
import SoundAnalysis

/// Bar heights worked out ahead of time, while the audio is decoded before it plays: live segments
/// as LiveLoader fetches them for the player, Xtra tracks as soon as they are downloaded.
/// Every 1024 samples get one frame, stamped with its place in the stream, so the bars are read
/// at the player's exact position: no recording permission, and they can't fall behind the music.
final class SpectrumTimeline: @unchecked Sendable {
    static let shared = SpectrumTimeline()

    /// `voice`: per frame, how sure Apple's on-device sound classifier is that someone is singing
    /// or rapping (0...1); nil when it couldn't say.
    private struct Chunk { let channel: String; let start: Date; let real: Date?; let sequence: Int; let hop: Double; let duration: Double; let frames: [[Float]]; let voice: [Float]? }
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
    /// Segment the player was last in: (sequence, its start in the item's timeline, its length).
    private var cursor: (sequence: Int, time: Double, duration: Double)?
    /// Tagged segment length (EXTINF): ~9.75 s from the API (LiveLoader); read from the playlist.
    private var nominal = 10.0
    /// Measured segment length: what the decoded audio of a segment really ran to (~9.75 s), so
    /// PDT extrapolation doesn't assume 10 s per segment and drift ahead of the real stream time.
    private var measured = 10.0
    private var live = [Chunk]()
    private var tracks = [URL: Track]()

    /// Live channels: LiveLoader hands over each playlist and the newest segments as it fetches them.
    func livePlaylist(_ text: String) { playlist(text) }
    func liveSegment(_ name: String, _ data: Data, _ key: Data?, iv: Data? = nil) { queue.async { self.segment(name, data, key, iv: iv) } }
    /// Whether some playlist has dated this segment yet (its place on the player's 10 s grid).
    func hasDate(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return segmentDates[name] != nil
    }

    // MARK: Live

    private func playlist(_ text: String) {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let tag = "#EXT-X-PROGRAM-DATE-TIME:"
        let plain = ISO8601DateFormatter()
        var dates = [String: Date]()
        var date: Date?
        var tagged: Double?
        var duration = 0.0
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst("#EXTINF:".count).prefix { $0 != "," }) ?? 0
                if tagged == nil { tagged = duration }
            } else if line.hasPrefix(tag) {
                let stamp = String(line.dropFirst(tag.count))
                date = f.date(from: stamp) ?? plain.date(from: stamp)
            } else if !line.hasPrefix("#"), let d = date, let name = line.split(separator: "/").last {
                dates[String(name)] = d
                // Only the first segment is tagged; the rest follow at their EXTINF lengths.
                date = d.addingTimeInterval(duration)
            }
        }
        // Modern-API masters also list a side playlist ("0152_209.aac") that isn't the audio the player
        // plays; it has no media sequence in its names and reset the anchor on every refresh (EQ died).
        dates = dates.filter { Self.sequence($0.key) != nil }
        guard let channel = dates.keys.first.map(Self.channel) else { return }
        lock.lock()
        if channel != liveChannel { anchor = nil; startSlot = nil; cursor = nil }
        if let tagged, tagged > 0 { nominal = tagged }
        if anchor == nil, let first = dates.min(by: { $0.value < $1.value }), let seq = Self.sequence(first.key) {
            anchor = (seq, first.value)
        }
        if let anchor {
            segmentDates = [:]
            for name in dates.keys {
                guard let seq = Self.sequence(name) else { continue }
                segmentDates[name] = anchor.date.addingTimeInterval(Double(seq - anchor.sequence) * nominal)
            }
        }
        realDates = dates
        liveChannel = channel
        live.removeAll { $0.channel != channel }
        lock.unlock()
    }

    /// Server thread hands each segment over before the player gets it; decrypt, decode and analyze here.
    private func segment(_ name: String, _ data: Data, _ key: Data?, iv: Data? = nil) {
        if data.isEmpty { return }
        lock.lock()
        let start = segmentDates[name]
        let done = live.contains { $0.start == start }
        lock.unlock()
        guard !done else { return }
        // Live segments have no explicit IV: HLS uses the media sequence number, the second-last field of the name.
        let parts = name.split(separator: "_")
        guard let start, let key, parts.count > 2, let sequence = Int(parts[parts.count - 2]),
              let plain = aes128Decrypt(data, key: key, iv: iv ?? Data(sequenceIV: sequence)) else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("StarPlayrX-\(name)")
        guard (try? stripID3(plain).write(to: file)) != nil else { return }
        defer { try? FileManager.default.removeItem(at: file) }
        var hop = 0.0
        var frames = [[Float]]()
        Self.decode(file) { h, _, f in hop = h; frames += f; return true }
        guard !frames.isEmpty, let audio = try? AVAudioFile(forReading: file) else { return }
        let duration = Double(audio.length) / audio.processingFormat.sampleRate   // ~9.75 s, not the tagged 10
        let voice = Self.voice(in: file, frames: frames.count, hop: hop)
        lock.lock()
        let real = realDates[name]
        lock.unlock()
        if let real { ShazamSync.shared.segment(file, real: real) }
        lock.lock()
        live.removeAll { $0.start == start }
        live.append(Chunk(channel: Self.channel(name), start: start, real: realDates[name], sequence: sequence,
                          hop: hop, duration: duration, frames: frames, voice: voice))
        if live.count > 30 { live.removeFirst(live.count - 30) }
        // What segments really hold, from the decoded audio: the player's date runs on the tagged
        // EXTINF per segment, so every untagged segment it stamps ran ~0.25 s further ahead than the
        // real PDT; this is what puts it back on the real time.
        if duration > 1, duration < nominal * 1.5 { measured = measured * 0.5 + duration * 0.5 }
        decodedCount += 1
        lock.unlock()
    }

    private var decodedCount = 0
    /// How many live segments have been decoded so far: goes up by one with each new one, so a
    /// caller can do its work once per segment whatever the segments' length.
    var decodedSegments: Int {
        lock.lock(); defer { lock.unlock() }
        return decodedCount
    }

    /// Bars for the live stream at the player item's current time. The item places the segment it
    /// starts on at its tagged position (10 s per segment before it), but from there on its clock runs
    /// on the audio itself, ~9.75 s per segment. Assuming 10 s put the bars 0.25 s further behind with
    /// every segment (1 s after 40 s, 2 s after 80 s), so walk the real decoded durations instead.
    /// One line of the live state, for the EQ dropout log in Radio.spectrumNow.
    var state: String {
        lock.lock(); defer { lock.unlock() }
        let seqs = live.map(\.sequence).sorted()
        return "anchor=\(anchor.map { "\($0.sequence)" } ?? "nil") slot=\(startSlot.map(String.init) ?? "nil") cursor=\(cursor.map { "\($0.sequence)@\(Int($0.time))" } ?? "nil") nominal=\(nominal) channel=\(liveChannel) dates=\(segmentDates.count) live=\(seqs.first.map { "\($0)…\(seqs.last ?? $0)(\(seqs.count))" } ?? "none")"
    }
    func levels(time: Double) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard let anchor, time >= 0 else { return nil }
        let start = startSlot ?? Int(time / nominal)
        startSlot = start
        // Resume from the segment found last time instead of walking from where playback started
        // every frame. That walk stopped after 60 segments, so the bars died ~10 minutes into a channel.
        if let c = cursor, time >= c.time {} else {
            var slot = start
            if time < Double(slot) * nominal { slot = Int(time / nominal) }   // seek back: tagged 10 s grid
            cursor = (anchor.sequence + slot, Double(slot) * nominal, 9.75)
        }
        guard var (sequence, segStart, lastDuration) = cursor else { return nil }
        while true {
            let c = live.first { $0.channel == liveChannel && $0.sequence == sequence }
            let duration = c?.duration ?? lastDuration
            let t = time - segStart
            if t < duration {
                cursor = (sequence, segStart, duration)
                guard let c, let last = c.frames.last else { return nil }
                let k = Int(t / c.hop)
                return k < c.frames.count ? c.frames[k] : last
            }
            segStart += duration
            lastDuration = duration
            sequence += 1
        }
    }

    /// How loud each band got *louder* from one frame to the next, summed: the onset strength of
    /// the audio that has already been decoded, on real broadcast time. Singing entering a quiet
    /// bar is a spike, which is what `LyricAligner` lines the lyrics up against. The frames are the
    /// equalizer's own, so this costs one subtraction per band and no extra decoding.
    /// Returns the first frame's real time, the seconds each frame covers, and the curve.
    func onsets() -> (start: Date, step: Double, values: [Float])? {
        lock.lock()
        defer { lock.unlock() }
        let sorted = live.filter { $0.channel == liveChannel && $0.real != nil }.sorted { $0.sequence < $1.sequence }
        // A gap in the segments breaks the timeline. Keep the unbroken run that ENDS at the newest
        // segment: keeping the one that starts at the oldest threw the whole song's audio away
        // whenever an older segment turned up late or one was skipped (58 s of audio fell to 39).
        var run = sorted.suffix(1)
        while let head = run.first, let i = sorted.firstIndex(where: { $0.sequence == head.sequence }), i > 0,
              sorted[i - 1].sequence == head.sequence - 1 {
            run = sorted[(i - 1)...]
        }
        let chunks = Array(run)
        guard let first = chunks.first, let start = first.real, first.hop > 0 else { return nil }
        var values = [Float]()
        var previous: [Float]?
        var expected = first.sequence
        for chunk in chunks {
            guard chunk.sequence == expected else { break }
            expected += 1
            for (k, frame) in chunk.frames.enumerated() {
                var flux: Float = 0
                if let previous, previous.count == frame.count, frame.count >= Self.vocal.upperBound {
                    // How much the bands where a voice sits (~320 Hz–3.5 kHz) rose, less how much
                    // the rest did. A voice coming in lifts its own bands; a drum hit or a cymbal
                    // lifts everything at once and cancels itself out. Averages, so the two sides
                    // weigh the same whatever their number of bands.
                    var inside: Float = 0, outside: Float = 0
                    for i in 0..<frame.count {
                        let rise = max(0, frame[i] - previous[i])
                        if Self.vocal.contains(i) { inside += rise } else { outside += rise }
                    }
                    let n = Float(Self.vocal.count)
                    flux = max(0, inside / n - outside / (Float(frame.count) - n))
                    // And mostly where the classifier hears singing or rapping, so a DJ talk-up,
                    // an ad or a busy instrumental break says less about where the lyrics sit.
                    if let voice = chunk.voice, k < voice.count { flux *= 0.2 + 0.8 * voice[k] }
                }
                values.append(flux)
                previous = frame
            }
        }
        return values.isEmpty ? nil : (start, first.hop, values)
    }

    /// The real on-air time (stream PDT) of the player's current date, which runs ahead of it.
    func realDate(at date: Date) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        // The player counts each segment as its tagged slot (EXTINF, ~10 s) but the segment holds
        // `measured` seconds of audio (~9.75 s), so within the slot the real time runs behind the
        // player's by that ratio — measured from the decoded audio, not assumed.
        let scale = min(1, measured / max(nominal, 1e-6))
        for (name, start) in segmentDates {
            let t = date.timeIntervalSince(start)
            guard t >= 0, t < nominal, let real = realDates[name] else { continue }
            return real.addingTimeInterval(t * scale)
        }
        return nil
    }

    /// The player starts a new item: it dates the stream afresh from the playlist it loads next.
    func resetLive() {
        lock.lock()
        anchor = nil
        startSlot = nil
        cursor = nil
        live.removeAll()
        lock.unlock()
    }

    private static func sequence(_ name: String) -> Int? {
        let parts = name.split(separator: "_")
        return parts.count > 2 ? Int(parts[parts.count - 2]) : nil
    }

    private static func channel(_ name: String) -> String { String(name.split(separator: "_").first ?? "") }

    /// The bars a singing voice lives in: band b starts at bin 2·186^(b/24), ~43 Hz a bin, so
    /// bands 6–16 run from ~320 Hz to ~3.5 kHz.
    private static let vocal = 6..<17

    /// Apple's built-in sound classifier (SoundAnalysis, on device) over one decoded segment, in
    /// one-second windows half overlapped: per equalizer frame, how sure it is a voice is singing
    /// or rapping. Speech is left out on purpose: that is the DJ. Nil if it couldn't run.
    private static func voice(in file: URL, frames: Int, hop: Double) -> [Float]? {
        guard hop > 0, let request = try? SNClassifySoundRequest(classifierIdentifier: .version1),
              let analyzer = try? SNAudioFileAnalyzer(url: file) else { return nil }
        request.windowDuration = CMTime(seconds: 1, preferredTimescale: 16_000)
        request.overlapFactor = 0.5
        let observer = VoiceObserver()
        guard (try? analyzer.add(request, withObserver: observer)) != nil else { return nil }
        analyzer.analyze()
        let windows = observer.windows
        guard !windows.isEmpty else { return nil }
        return (0..<frames).map { k in
            let t = Double(k) * hop
            return windows.filter { t >= $0.start && t < $0.end }.map(\.voice).max() ?? 0
        }
    }

    private final class VoiceObserver: NSObject, SNResultsObserving {
        static let labels: Set<String> = ["singing", "choir_singing", "rapping", "humming", "yodeling"]
        var windows = [(start: Double, end: Double, voice: Float)]()
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let voice = result.classifications.filter { Self.labels.contains($0.identifier) }.map(\.confidence).max() ?? 0
            let range = result.timeRange
            windows.append((range.start.seconds, range.end.seconds, Float(voice)))
        }
    }

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
