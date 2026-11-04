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

    /// The song the shift belongs to, and the shift itself. Published so the pane can show it.
    @Published private(set) var key = ""
    @Published private(set) var shift: Double?
    /// Set when the shift came from the user clicking a line rather than from the aligner. The
    /// person listening is the better judge, so no later measurement overrules it; cleared when
    /// the song changes.
    @Published private(set) var isPinned = false
    /// The last measurement, for the `lyric sync` scripting property.
    private(set) var report = "no measurement yet"
    /// Another measurement is taken each time a new segment of audio has been decoded (~9.75 s on
    /// live channels), so it stays in step with the segments whatever their length, and a DJ break,
    /// ad or dead air between songs never leaves it waiting on a timer. Each one looks at everything
    /// decoded so far, so the later ones have more to go on than the first.
    /// `SpectrumTimeline.decodedSegments` at the last measurement; -1 forces one right away.
    private var lastSegment = -1

    /// The measured shift for this song, or nil while there isn't a confident one (the caller
    /// falls back to `Radio.liveLyricsLead`).
    func shift(forKey key: String) -> Double? { key == self.key ? shift : nil }

    /// The shift the user pinned by clicking a line, for the players that have no measured shift
    /// of their own (Xtra tracks, where the position comes straight out of the player).
    func pinnedShift(forKey key: String) -> Double? { isPinned ? shift(forKey: key) : nil }

    /// Takes the user's word for where the song is: the shift that puts the line they clicked
    /// under the music playing at that moment. `remember` keeps it for the next time the song
    /// turns up, which only means the same thing on a live channel — an Xtra track's position is
    /// the file's own, not a cut's stamp.
    func pin(shift: Double, forKey key: String, remember: Bool) {
        self.key = key
        self.shift = shift
        isPinned = true
        report = String(format: "pinned by hand %+.1fs", shift)
        if remember { LyricsCache.shared.saveShift(shift, for: key) }
    }

    /// Called on the lyrics pane's tick. Measures once per newly decoded segment, and only replaces what
    /// it has when the new measurement stands out further than the old one did.
    func update(lyrics: Lyrics, key: String, songStart: Date) {
        if key != self.key {
            self.key = key
            shift = LyricsCache.shared.shift(for: key)
            report = shift.map { "remembered \(String(format: "%+.1f", $0))s" } ?? "no measurement yet"
            isPinned = false
            lastSegment = -1
        }
        let segment = SpectrumTimeline.shared.decodedSegments
        guard !isPinned, lyrics.synced, segment != lastSegment else { return }

        lastSegment = segment
        // Only lines the pane draws: an LRC times the gaps between verses as empty lines, and
        // nobody sings those, so they would drag the match towards silence. Where the source times
        // every word, each word is a moment too: a rap verse gives the aligner ten points a line
        // instead of one. Words within a tenth of a second of the last are the same moment.
        let stamps = lyrics.lines.flatMap { $0.text.isEmpty ? [] : ($0.at.map { [$0] } ?? []) + $0.words }
        var times = [Double]()
        for at in stamps.sorted() where at - (times.last ?? -.infinity) >= 0.1 { times.append(at) }
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
