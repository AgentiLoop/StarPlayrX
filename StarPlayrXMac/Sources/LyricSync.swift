//
//  LyricSync.swift
//  StarPlayrXMac
//
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  Keeps the measured shift for the song playing now. `LyricAligner` does the measuring, from the
//  equalizer's own frames; this decides when to measure, whether the new answer is better than the
//  one it already has, and remembers it per song so the next time that song turns up the lines are
//  in step from the first one.
//

import Foundation

@MainActor
final class LyricSync: ObservableObject {
    static let shared = LyricSync()

    /// How often another measurement is taken while a song plays. Each one looks at everything
    /// decoded so far, so the later ones have more to go on than the first.
    static let interval: TimeInterval = 15

    /// The song the shift belongs to, and the shift itself. Published so the pane can show it.
    @Published private(set) var key = ""
    @Published private(set) var shift: Double?
    /// The last measurement, for the `lyric sync` scripting property.
    private(set) var report = "no measurement yet"
    private var lastTry = Date.distantPast

    /// The measured shift for this song, or nil while there isn't a confident one (the caller
    /// falls back to `Radio.liveLyricsLead`).
    func shift(forKey key: String) -> Double? { key == self.key ? shift : nil }

    /// Called on the lyrics pane's tick. Measures at most every `interval`, and only replaces what
    /// it has when the new measurement stands out further than the old one did.
    func update(lyrics: Lyrics, key: String, songStart: Date) {
        if key != self.key {
            self.key = key
            shift = LyricsCache.shared.shift(for: key)
            report = shift.map { "remembered \(String(format: "%+.1f", $0))s" } ?? "no measurement yet"
            lastTry = .distantPast
        }
        guard lyrics.synced, Date().timeIntervalSince(lastTry) >= Self.interval else { return }
        lastTry = Date()
        // Only lines the pane draws: an LRC times the gaps between verses as empty lines, and
        // nobody sings those, so they would drag the match towards silence.
        let times = lyrics.lines.compactMap { $0.text.isEmpty ? nil : $0.at }
        guard times.count >= LyricAligner.minimumLines else {
            report = "only \(times.count) timed lines"
            return
        }
        guard let onsets = SpectrumTimeline.shared.onsets() else {
            report = "no decoded audio yet"
            return
        }
        let audio = Double(onsets.values.count) * onsets.step
        guard let found = LyricAligner.align(lineTimes: times, songStart: songStart, onsets: onsets) else {
            report = String(format: "no confident match (%.0fs of audio, %d lines)", audio, times.count)
            return
        }
        // The newest measurement wins: every one looks at more of the song than the last, and a
        // later lock is the one that had the most to go on.
        shift = found.shift
        report = String(format: "%+.1fs (confidence %.1f, margin %.2f, %d lines, %.0fs of audio)",
                        found.shift, found.confidence, found.margin, found.lines, audio)
        LyricsCache.shared.saveShift(found.shift, for: key)
    }
}
