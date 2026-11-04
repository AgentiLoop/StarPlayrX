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
import AppKit

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

    /// The model's own tick. Measuring used to ride on the lyrics pane's redraw timer, and macOS
    /// stops redrawing a hidden window, so with the window hidden nothing was measured, Shazam
    /// stopped matching and a new song's lyrics never loaded: the words came back way out of step.
    private var timer: Timer?
    /// Held while a live channel plays, so App Nap doesn't slow the timer and the decoding down
    /// when the window is hidden or covered.
    private var activity: NSObjectProtocol?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in LyricSync.shared.tick() }
        }
        timer?.tolerance = 0.1
        // Back on screen: measure now rather than waiting for the next segment.
        let names = [NSApplication.didUnhideNotification, NSApplication.didBecomeActiveNotification,
                     NSWindow.didChangeOcclusionStateNotification]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in LyricSync.shared.remeasure() }
            }
        }
    }

    private func remeasure() {
        lastSegment = -1
        tick()
    }

    private func tick() {
        let radio = Radio.shared
        let live = radio.isPlaying && radio.current != nil && radio.current?.xtraID == nil
        if live, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "Live radio: keeping the lyrics in step")
        } else if !live, let held = activity {
            ProcessInfo.processInfo.endActivity(held)
            activity = nil
        }
        guard radio.isLoggedIn, MenuController.shared.lyrics else { return }
        // Load the lyrics for whatever is on now, even while the pane can't redraw (repeat calls
        // for the same song do nothing).
        let showing = radio.playingNow ?? radio.current.flatMap { radio.nowPlaying[$0.id] }
        LyricsStore.shared.show(artist: showing?.artist ?? "", song: showing?.song ?? "", duration: radio.trackDuration)
        guard live, let lyrics = LyricsStore.shared.lyrics, let channel = radio.current,
              let np = radio.nowPlaying[channel.id], let started = np.startedAt else { return }
        update(lyrics: lyrics, key: LyricsStore.key(np.artist, np.song), songStart: started)
    }

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
    @discardableResult
    func pin(shift: Double, forKey key: String, remember: Bool) -> Bool {
        // A click a minute or more away from where the song is can't be "this line is being sung
        // now" (a stray click, or the pane drawn from a stale position): it threw a song 2 minutes out.
        guard abs(shift) <= 60 else { return false }
        self.key = key
        self.shift = shift
        isPinned = true
        report = String(format: "pinned by hand %+.1fs", shift)
        if remember { LyricsCache.shared.saveShift(shift, for: key) }
        return true
    }

    /// Called on the model's own tick (`tick`). Measures once per newly decoded segment, and only replaces what
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
        // Shazam first: when it has heard this very song, it knows outright how far into the
        // record the audio on air is, and that beats anything worked out from the audio. Only
        // when it hasn't (a song not in its catalogue, a talk-up, matching not set up) does the
        // aligner below have its say.
        ShazamSync.shared.want()
        let (match, error) = ShazamSync.shared.current
        if let match, Self.same(match, as: key) {
            // At broadcast time `match.real` the record was `match.offset` seconds in; the cut's
            // stamp put that moment `real - songStart` in. The difference is the shift.
            let found = match.offset - match.real.timeIntervalSince(songStart)
            if abs(found) <= 60 {
                shift = found
                report = String(format: "%+.1fs (Shazam: %@ – %@ at %.1fs)", found, match.artist, match.title, match.offset)
                LyricsCache.shared.saveShift(found, for: key)
                return
            }
        }
        let shazam = error.map { " · Shazam: \($0)" } ?? ""
        // Only lines the pane draws: an LRC times the gaps between verses as empty lines, and
        // nobody sings those, so they would drag the match towards silence. Where the source times
        // every word, each word is a moment too: a rap verse gives the aligner ten points a line
        // instead of one. Words within a tenth of a second of the last are the same moment.
        let stamps = lyrics.lines.flatMap { $0.text.isEmpty ? [] : ($0.at.map { [$0] } ?? []) + $0.words }
        var times = [Double]()
        for at in stamps.sorted() where at - (times.last ?? -.infinity) >= 0.1 { times.append(at) }
        guard times.count >= LyricAligner.minimumLines else {
            report = "only \(times.count) timed lines" + shazam
            return
        }
        guard let onsets = SpectrumTimeline.shared.onsets() else {
            report = "no decoded audio yet" + shazam
            return
        }
        let audio = Double(onsets.values.count) * onsets.step
        guard let found = LyricAligner.align(lineTimes: times, songStart: songStart, onsets: onsets) else {
            report = String(format: "no confident match (%.0fs of audio, %d lines)", audio, times.count) + shazam
            return
        }
        // The newest measurement wins: every one looks at more of the song than the last, and a
        // later lock is the one that had the most to go on.
        shift = found.shift
        report = String(format: "%+.1fs (confidence %.1f, margin %.2f, %d lines, %.0fs of audio)",
                        found.shift, found.confidence, found.margin, found.lines, audio) + shazam
        LyricsCache.shared.saveShift(found.shift, for: key)
    }

    /// Whether Shazam heard the song the lyrics are for (`key` is "artist|song", lowercased).
    /// Loose on purpose: the station says "Lose Yourself", Shazam "Lose Yourself (From "8 Mile")";
    /// the artist one way round or the other ("Eminem" / "Eminem & Dido").
    static func same(_ match: ShazamSync.Match, as key: String) -> Bool {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        func plain(_ s: String) -> String {
            LyricsStore.withoutParentheses(s).lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let (artist, song) = (plain(parts[0]), plain(parts[1]))
        let (heardArtist, heardSong) = (plain(match.artist), plain(match.title))
        guard !artist.isEmpty, !song.isEmpty, !heardArtist.isEmpty, !heardSong.isEmpty else { return false }
        return (heardSong.contains(song) || song.contains(heardSong))
            && (heardArtist.contains(artist) || artist.contains(heardArtist))
    }
}
