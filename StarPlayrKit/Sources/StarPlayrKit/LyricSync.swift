//
//  LyricSync.swift
//  StarPlayrKit
//
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  Keeps the measured shift for the song playing now. `LyricAligner` does the measuring, from the
//  equalizer's own frames; this decides when to measure, whether the new answer is better than the
//  one it already has, and remembers it per song so the next time that song turns up the lines are
//  in step from the first one.
//

import Foundation
import os
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
public final class LyricSync: ObservableObject {
    public static let shared = LyricSync()

    /// The song the shift belongs to, and the shift itself. Published so the pane can show it.
    @Published public private(set) var key = ""
    @Published public private(set) var shift: Double?
    /// Set when the shift came from the user clicking a line rather than from the aligner. The
    /// person listening is the better judge, so no later measurement overrules it; cleared when
    /// the song changes.
    @Published public private(set) var isPinned = false
    /// The last measurement, for the `lyric sync` scripting property.
    public private(set) var report = "no measurement yet"
    /// Another measurement is taken each time a new segment of audio has been decoded (~9.75 s on
    /// live channels), so it stays in step with the segments whatever their length, and a DJ break,
    /// ad or dead air between songs never leaves it waiting on a timer. Each one looks at everything
    /// decoded so far, so the later ones have more to go on than the first.
    /// `SpectrumTimeline.decodedSegments` at the last measurement; -1 forces one right away.
    private var lastSegment = -1
    /// `NowPlaying.startedAt` at the lock, so the same song playing again (a replay an hour later)
    /// is a new song, not the same one whose lock is still good.
    private var lockedAt: Date?

    /// What placed the current shift this song: Shazam, or the aligner with that confidence.
    /// nil = nothing yet (or only a shift remembered from last time), so any lock replaces it.
    private enum Source: Equatable { case shazam, aligner(Double) }
    private var heldBy: Source?
    /// A Shazam match placing the song somewhere else than the Shazam lock held, waiting for a
    /// later match to agree with it before the lock moves.
    private var doubtedShift: (shift: Double, found: Date)?
    /// `found` of the last Shazam match taken in, so one match counts once.
    private var lastMatchFound: Date?
    /// The shift from every Shazam match agreeing with the lock; the lock is their mean.
    private var shazamSamples = [Double]()
    private var shazamMean: Double? {
        shazamSamples.isEmpty ? nil : shazamSamples.reduce(0, +) / Double(shazamSamples.count)
    }
    /// Live channels' `xtraTune`: each confident aligner reading within `liveTuneLimit` of the Shazam
    /// lock, minus the lock; their mean (capped) fine-tunes the lock.
    private var liveTunes = [Double]()
    private static let liveTuneLimit: TimeInterval = 1.5
    private var liveTune: Double {
        guard !liveTunes.isEmpty else { return 0 }
        let mean = liveTunes.reduce(0, +) / Double(liveTunes.count)
        return min(max(mean, -Self.liveTuneLimit), Self.liveTuneLimit)
    }
    /// An aligner lock within this many seconds of the one held is the same lock, refined.
    /// 0.5 s rather than a second: a lock that moves by more than half a second is a different
    /// place in the song, and keeping the old one is what parked the highlight a line or two out.
    private static let agree = 0.5

    /// The model's own tick. Measuring used to ride on the lyrics pane's redraw timer, and macOS
    /// stops redrawing a hidden window, so with the window hidden nothing was measured, Shazam
    /// stopped matching and a new song's lyrics never loaded: the words came back way out of step.
    private var timer: Timer?
    /// Held while a live channel plays, so App Nap doesn't slow the timer and the decoding down
    /// when the window is hidden or covered.
    private var activity: NSObjectProtocol?
    /// Whether the lyrics are on screen (on the Mac, MenuController's lyrics pane): nothing is
    /// looked up or measured while they aren't.
    private var lyricsShown: @MainActor () -> Bool = { false }

    public func start(lyricsShown: @escaping @MainActor () -> Bool) {
        guard timer == nil else { return }
        self.lyricsShown = lyricsShown
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in LyricSync.shared.tick() }
        }
        timer?.tolerance = 0.1
        // Back on screen: measure now rather than waiting for the next segment.
        #if os(macOS)
        // Not NSWindow.didChangeOcclusionStateNotification: with object nil it fired for every
        // window (panel, bubble popups, menus), re-running the aligner on main each time. iOS has no such trigger.
        let names = [NSApplication.didUnhideNotification, NSApplication.didBecomeActiveNotification]
        #else
        let names = [UIApplication.didBecomeActiveNotification]
        #endif
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
        guard radio.isLoggedIn else { return }
        checkNames(radio, live: live)
        guard lyricsShown() else { return }
        // Load the lyrics for whatever is on now, even while the pane can't redraw (repeat calls
        // for the same song do nothing).
        let showing = radio.lyricsSong
        LyricsStore.shared.show(artist: showing?.artist ?? "", song: showing?.song ?? "", duration: radio.trackDuration)
        if radio.isPlaying, radio.current?.xtraID != nil { xtra(); return }
        // No lyrics under the station's names: ask Shazam what is on air and look again under its
        // artist and title. Only a match heard since this song started counts.
        if live, LyricsStore.shared.missed, let channel = radio.current, let np = radio.nowPlaying[channel.id] {
            let match = ShazamSync.shared.current.match
            let fresh = match.flatMap { m in np.startedAt.map { m.real >= $0 } ?? true } ?? false
            ShazamSync.shared.want(eager: !fresh)
            if fresh, let match {
                LyricsStore.shared.tryHeard(artist: match.artist, song: match.title, duration: nil)
            }
            return
        }
        guard live, let lyrics = LyricsStore.shared.lyrics, let channel = radio.current,
              let np = radio.nowPlaying[channel.id], let started = np.startedAt else { return }
        update(lyrics: lyrics, key: LyricsStore.key(np.artist, np.song), songStart: started)
    }

    /// The channel last ticked, so a Shazam match heard on the one before isn't taken for this one.
    private var channel: String?
    /// A match naming another song than the station does, waiting for a second match to agree, so
    /// one stray match (a DJ over a music bed, a jingle) doesn't rename the song.
    private var doubted: (key: String, found: Date)?

    /// The station's artist and title blank, or naming another song than Shazam hears on air: Shazam's
    /// names stand in for them (`Radio.hear`), in Now Playing and for the lyrics, which are then
    /// looked up under those names. Runs whether or not the lyrics are on screen. Xtra: see `xtra()`.
    private func checkNames(_ radio: Radio, live: Bool) {
        if radio.current?.id != channel {
            channel = radio.current?.id
            doubted = nil
            ShazamSync.shared.reset()
        }
        guard live, let station = radio.stationNowPlaying else { return }
        let blank = Self.isBlank(station)
        let shown = radio.playingNow.map { LyricsStore.key($0.artist, $0.song) }
        // Listen all the time on a live channel (every half minute; every segment while the names
        // are blank or a doubt waits to be confirmed), so wrong names are caught with the pane shut.
        ShazamSync.shared.want(eager: (blank && shown == LyricsStore.key(station.artist, station.song)) || doubted != nil)
        // Only a match heard since this cut started counts.
        guard let match = ShazamSync.shared.current.match, !match.title.isEmpty,
              station.startedAt.map({ match.real >= $0 }) ?? true else { return }
        guard blank || !Self.same(match, as: LyricsStore.key(station.artist, station.song)) else { doubted = nil; return }
        let heard = LyricsStore.key(match.artist, match.title)
        guard heard != shown else { doubted = nil; return }
        if !blank {
            guard let doubt = doubted, doubt.key == heard, match.found > doubt.found else {
                if doubted?.key != heard || doubted == nil { doubted = (heard, match.found) }
                return
            }
        }
        doubted = nil
        // Shazam timed the record: the song really started `offset` before `real`. Else the station's
        // cut start stands, or with none (blank names) the moment it was heard.
        let start = match.offset > 0.5 ? match.real.addingTimeInterval(-match.offset) : (station.startedAt == nil ? match.real : nil)
        radio.hear(artist: match.artist, song: match.title, startedAt: start)
    }

    private static func isBlank(_ np: NowPlaying) -> Bool {
        np.artist.trimmingCharacters(in: .whitespaces).isEmpty || np.song.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The measured shift for this song, or nil while there isn't a confident one (the caller
    /// falls back to `Radio.liveLyricsLead`).
    public func shift(forKey key: String) -> Double? { key == self.key ? shift : nil }

    /// The shift the user pinned by clicking a line, for the players that have no measured shift
    /// of their own (Xtra tracks, where the position comes straight out of the player).
    public func pinnedShift(forKey key: String) -> Double? { isPinned ? shift(forKey: key) : nil }

    /// Xtra tracks: the player knows where the file is, but not where the record is — the file can
    /// be another edit, or have its own lead-in, and the lyrics are timed to the record. Shazam
    /// says how far into the record a stretch of the file is, so the difference is the shift.
    /// One match per track is enough: the file doesn't drift. Until Shazam has one (no match, no
    /// timing, or a shift too large to be right) the aligner measures the file's own audio, the
    /// same fallback the live channels have; with neither, the player's position stands.
    private var xtraFile: URL?
    private var xtraFound: Double?
    private var xtraTries = 0
    private var xtraAsked = Date.distantPast
    /// The aligner's shift for this file, and when it last measured.
    private var xtraAligned: Double?
    private var xtraAlignedAt = Date.distantPast
    /// Xtra tracks come as the same ~9.75 s segments as the live channels: Shazam hears one
    /// segment's worth at a time, one segment apart, and the aligner measures as often.
    private static let xtraSegment: TimeInterval = 9.75
    /// A file position more than one segment away from the record is way off, not a lead-in:
    /// anything larger is thrown away rather than moving the lyrics.
    private static let xtraMaxShift: TimeInterval = 9.75
    /// The aligner moves an Xtra track only by more than this. Measured on the Mac (16 Xtra tracks,
    /// Nov 2026, aligner vs Shazam on the same file): the file's own position was within 0.5 s of
    /// Shazam on 15 of them (mean 0.34 s), while the aligner's confident answers were 0.11–0.52 s
    /// out — worse than not moving at all. Only a lead-in or another edit (seconds, not tenths) is
    /// worth taking from it.
    private static let xtraAlignerMinimum: TimeInterval = 1.0
    /// Once Shazam has placed the track, a confident aligner reading this close to it is the lyric
    /// file's own timing error, not a misplaced track: the highlight is fine-tuned by the average of
    /// those readings, never by more than this. Further out is the aligner being wrong, and ignored.
    private static let xtraTuneLimit: TimeInterval = 1.5
    /// Each accepted aligner-minus-Shazam reading for this file.
    private var xtraTunes = [Double]()
    /// The average of `xtraTunes`, capped at `xtraTuneLimit`; 0 with none.
    private var xtraTune: Double {
        guard !xtraTunes.isEmpty else { return 0 }
        let mean = xtraTunes.reduce(0, +) / Double(xtraTunes.count)
        return min(max(mean, -Self.xtraTuneLimit), Self.xtraTuneLimit)
    }

    /// The shift for this Xtra file: Shazam's fine-tuned by the aligner once there is one, else the
    /// aligner's. A hand pin overrules both (`pinnedShift`, checked first by the callers).
    public func xtraShift(for file: URL) -> Double? { file == xtraFile ? (xtraFound.map { $0 + xtraTune } ?? xtraAligned) : nil }

    private func xtra() {
        // Timed lyrics to line up, or none at all under the station's names: then Shazam's names
        // are the next thing to look them up by.
        guard let (file, at) = Radio.shared.xtraNow, let np = Radio.shared.playingNow,
              LyricsStore.shared.missed || LyricsStore.shared.lyrics?.synced == true || Self.isBlank(np) else { return }
        if file != xtraFile {
            xtraFile = file; xtraFound = nil; xtraTries = 0; xtraAsked = .distantPast
            xtraAligned = nil; xtraAlignedAt = .distantPast; xtraTunes = []
        }
        xtraAlign(file)
        // Wait out the first seconds (a fade-in or silence matches nothing), then ask once a segment
        // (so a request that failed has had its answer) until Shazam places the track. Until then the
        // fallback (aligner, else the player's position) times the lyrics.
        guard xtraFound == nil, at >= 3, Date().timeIntervalSince(xtraAsked) >= Self.xtraSegment else { return }
        xtraTries += 1
        xtraAsked = Date()
        let key = LyricsStore.key(np.artist, np.song)
        ShazamSync.shared.track(file, at: at) { match in
            Task { @MainActor in
                let sync = LyricSync.shared
                guard sync.xtraFile == file else { return }
                let store = LyricsStore.shared
                guard let match, !match.title.isEmpty else {
                    sync.report = "Xtra: no Shazam match yet (try \(sync.xtraTries))" + sync.xtraFallback
                    return
                }
                // Blank names, or Shazam heard another song than the track says: its names stand in,
                // and the lyrics are looked up under them. Its timing is of this file's audio either way,
                // so it is kept below rather than thrown away.
                let renamed = Self.isBlank(np) || !Self.same(match, as: key)
                if renamed {
                    Radio.shared.hear(artist: match.artist, song: match.title, startedAt: nil)
                } else if store.missed {
                    store.tryHeard(artist: match.artist, song: match.title, duration: Radio.shared.trackDuration)
                }
                // No usable timing from Shazam: the fallback stands. (After a rename the lyrics on hand
                // are the old song's, so only the offset itself is checked.)
                guard Self.hasTiming(match, lyrics: renamed ? nil : store.lyrics) else {
                    sync.report = "Xtra: Shazam gave no timing (try \(sync.xtraTries))" + sync.xtraFallback
                    return
                }
                let found = match.offset - at
                guard abs(found) <= Self.xtraMaxShift else {
                    sync.report = String(format: "Xtra: ignored Shazam %+.1fs, more than %.2fs is way off (try %d)",
                                         found, Self.xtraMaxShift, sync.xtraTries) + sync.xtraFallback
                    return
                }
                sync.xtraFound = found
                sync.report = String(format: "Xtra %+.1fs (Shazam: %@ – %@ at %.1fs)", found, match.artist, match.title, match.offset)
            }
        }
    }

    /// What the Xtra lyrics are timed by while Shazam has nothing usable, for the report.
    private var xtraFallback: String {
        xtraAligned.map { String(format: " · using aligner %+.1fs", $0) } ?? " · using the player's position"
    }

    /// The live channels' fallback, on the Xtra file: the aligner lines the lyrics up with the
    /// file's own audio, once a segment. It keeps measuring after Shazam has placed the track:
    /// its confident readings close to Shazam fine-tune the highlight (`xtraTune`).
    private func xtraAlign(_ file: URL) {
        guard let lyrics = LyricsStore.shared.lyrics, lyrics.synced,
              Date().timeIntervalSince(xtraAlignedAt) >= Self.xtraSegment,
              let onsets = SpectrumTimeline.shared.onsets(track: file) else { return }
        xtraAlignedAt = Date()
        let times = Self.lineTimes(lyrics)
        guard times.count >= LyricAligner.minimumLines else { return }
        let origin = Date(timeIntervalSinceReferenceDate: 0)
        // #2 the classifier's singing curve (once it has been through the file), #3 the onsets.
        let singing = SpectrumTimeline.shared.singing(track: file)
        let bySinging = singing.flatMap { LyricAligner.align(lineTimes: times, songStart: origin, onsets: $0) }
        let by = bySinging != nil ? "singing" : "onsets"
        guard let found = bySinging ?? LyricAligner.align(lineTimes: times, songStart: origin, onsets: onsets) else {
            return
        }
        // The aligner says line t is sung at t + shift seconds into the file; the lyrics are drawn
        // at file position + Xtra shift, so the Xtra shift is the opposite of it.
        let shift = -found.shift
        // Confident and close to Shazam: a sample of the lyric file's own timing error.
        if let shazam = xtraFound, abs(shift - shazam) <= Self.xtraTuneLimit {
            xtraTunes.append(shift - shazam)
            report = String(format: "Xtra %+.2fs (Shazam %+.2fs, fine-tuned %+.2fs by the aligner over %d readings)",
                            shazam + xtraTune, shazam, xtraTune, xtraTunes.count)
        }
        guard abs(shift) <= Self.xtraMaxShift, abs(shift) >= Self.xtraAlignerMinimum else { xtraAligned = nil; return }
        xtraAligned = shift
        if xtraFound == nil {
            report = String(format: "Xtra %+.1fs (aligner, %@: confidence %.1f, margin %.2f, %d lines)",
                            shift, by, found.confidence, found.margin, found.lines)
        }
    }

    /// The moments the aligner lines up with the audio: only lines the pane draws (an LRC times
    /// the gaps between verses as empty lines, and nobody sings those), plus every word where the
    /// source times them. Words within a tenth of a second of the last are the same moment.
    public static func lineTimes(_ lyrics: Lyrics) -> [Double] {
        let stamps = lyrics.lines.flatMap { $0.text.isEmpty ? [] : ($0.at.map { [$0] } ?? []) + $0.words }
        var times = [Double]()
        for at in stamps.sorted() where at - (times.last ?? -.infinity) >= 0.1 { times.append(at) }
        return times
    }

    /// Takes the user's word for where the song is: the shift that puts the line they clicked
    /// under the music playing at that moment. `remember` keeps it for the next time the song
    /// turns up, which only means the same thing on a live channel — an Xtra track's position is
    /// the file's own, not a cut's stamp.
    @discardableResult
    public func pin(shift: Double, forKey key: String, remember: Bool) -> Bool {
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
    public func update(lyrics: Lyrics, key: String, songStart: Date) {
        if key != self.key {
            self.key = key
            // Only trust a remembered shift that measured this song in THIS cut: a shift saved from a
            // different edit of the same song (a radio edit against the album record) is out by more
            // than the search allows for and drags every line off. A shift of a second or less comes
            // from the same cut and is safe to start from.
            let remembered = LyricsCache.shared.shift(for: key).flatMap { abs($0) <= 2 ? $0 : nil }
            shift = remembered
            report = remembered.map { "remembered \(String(format: "%+.1f", $0))s" } ?? "no measurement yet"
            isPinned = false
            heldBy = nil
            doubtedShift = nil
            lastMatchFound = nil
            shazamSamples = []
            liveTunes = []
            lockedAt = nil
            lastSegment = -1
        }
        let segment = SpectrumTimeline.shared.decodedSegments
        guard !isPinned, lyrics.synced, segment != lastSegment else { return }
        // The same song again (replayed later, or re-tuned): its old lock was measured against the
        // last time it played, so start clean rather than holding a lock for a song that isn't on.
        if let locked = lockedAt, abs(songStart.timeIntervalSince(locked)) > 120 {
            heldBy = nil
            shift = nil
            lockedAt = nil
            doubtedShift = nil
            shazamSamples = []
            liveTunes = []
            report = "same song again: re-measuring"
        }

        lastSegment = segment
        // Shazam first: when it has heard this very song, it knows outright how far into the
        // record the audio on air is, and that beats anything worked out from the audio. Only
        // when it hasn't (a song not in its catalogue, a talk-up, matching not set up) does the
        // aligner below have its say.
        let (match, error) = ShazamSync.shared.current
        let heard = match.map { Self.heard($0, key: key) } ?? false
        // Shazam knew the song but gave no usable timing for it: its names still count, its offset
        // doesn't, and the lyrics stay on the fallback (the aligner, else the remembered shift or
        // the cut's stamp) instead of being thrown wherever a bad offset puts them.
        let timed = match.map { Self.hasTiming($0, lyrics: lyrics) } ?? false
        // Until Shazam has timed this song, ask on every segment rather than every half minute;
        // and again while a match that disagrees with the lock waits for a second one.
        ShazamSync.shared.want(eager: !(heard && timed) || doubtedShift != nil)
        // Each match is taken in once; the same match seen again on the next segment is nothing new.
        if let match, heard, timed, match.found != lastMatchFound {
            lastMatchFound = match.found
            // At broadcast time `match.real` the record was `match.offset` seconds in; the cut's
            // stamp put that moment `real - songStart` in. The difference is the shift. Shazam
            // heard this very song, so its word stands even when the cut's stamp is minutes out
            // (it used to be thrown away past a minute, leaving the lyrics way off until a re-tune).
            let found = match.offset - match.real.timeIntervalSince(songStart)
            if abs(found) <= 600 {
                if heldBy == .shazam, let held = shazamMean, abs(found - held) > Self.agree {
                    // Shazam has already placed this song and this match says somewhere else (a chorus
                    // or riff that repeats, matched at the wrong one of them): one stray match threw
                    // the lyrics 27 s out mid-song. It takes two matches in a row agreeing with each
                    // other to move a Shazam lock, and the next one is asked for on the next segment.
                    if let doubt = doubtedShift, abs(found - doubt.shift) <= Self.agree {
                        shazamSamples = [doubt.shift, found]
                        liveTunes = []
                    } else {
                        doubtedShift = (found, match.found)
                        ShazamSync.shared.want(eager: true)
                        report = String(format: "kept %+.1fs; Shazam now says %+.1fs (at %.1fs), waiting for a second match to agree",
                                        held, found, match.offset)
                        return
                    }
                } else if heldBy == .shazam {
                    // Agrees with the lock: Shazam's offset jitters ±0.3 s from one match to the next,
                    // so the lock is the mean of every agreeing match rather than the newest one.
                    shazamSamples.append(found)
                } else {
                    shazamSamples = [found]
                    liveTunes = []
                }
                doubtedShift = nil
                heldBy = .shazam
                let mean = shazamMean ?? found
                shift = mean + liveTune
                lockedAt = songStart
                report = String(format: "%+.2fs (Shazam: %@ – %@ at %.1fs, %d match%@ averaged%@)", shift ?? mean,
                                match.artist, match.title, match.offset, shazamSamples.count, shazamSamples.count == 1 ? "" : "es",
                                liveTunes.isEmpty ? "" : String(format: ", aligner tune %+.2fs", liveTune))
                LyricsCache.shared.saveShift(shift ?? mean, for: key)
                return
            }
        }
        // Shazam already placed this song: its lock stands, and from here the aligner only fine-tunes
        // it (`liveTune`), as `xtraTune` does for an Xtra track; it never moves the lock itself.
        let tuning = heldBy == .shazam
        let shazam = (heard && !timed ? " · Shazam: no timing, using fallback" : "")
            + (error.map { " · Shazam: \($0)" } ?? "")
        // Only lines the pane draws: an LRC times the gaps between verses as empty lines, and
        // nobody sings those, so they would drag the match towards silence. Where the source times
        // every word, each word is a moment too: a rap verse gives the aligner ten points a line
        // instead of one. Words within a tenth of a second of the last are the same moment.
        let stamps = lyrics.lines.flatMap { $0.text.isEmpty ? [] : ($0.at.map { [$0] } ?? []) + $0.words }
        var times = [Double]()
        for at in stamps.sorted() where at - (times.last ?? -.infinity) >= 0.1 { times.append(at) }
        guard times.count >= LyricAligner.minimumLines else {
            if !tuning { report = "only \(times.count) timed lines" + shazam }
            return
        }
        // #2, Apple's sound classifier: how sure it is someone is singing, frame by frame. A line
        // starts where the singing comes in, so that is lined up first. #3, when it can't be sure
        // (singing straight through a verse leaves few rises, or no classifier): the voice-band
        // onsets. Both pass the same confidence and margin gates.
        let singing = SpectrumTimeline.shared.singing()
        let bySinging = singing.flatMap { LyricAligner.align(lineTimes: times, songStart: songStart, onsets: $0) }
        guard let onsets = bySinging != nil ? singing : SpectrumTimeline.shared.onsets() else {
            if !tuning { report = "no decoded audio yet" + shazam }
            return
        }
        let by = bySinging != nil ? "singing" : "onsets"
        let audio = Double(onsets.values.count) * onsets.step
        guard let found = bySinging ?? LyricAligner.align(lineTimes: times, songStart: songStart, onsets: onsets) else {
            if !tuning {
                report = String(format: "no confident match (%.0fs of audio, %d lines)", audio, times.count) + shazam
            }
            return
        }
        if tuning {
            // A confident reading this close to Shazam's lock is the lyric file's own timing error,
            // not a misplaced song: the lock is fine-tuned by the mean of those readings, never by
            // more than `liveTuneLimit`. Further out is the aligner being wrong, and ignored.
            guard let base = shazamMean, abs(found.shift - base) <= Self.liveTuneLimit else { return }
            liveTunes.append(found.shift - base)
            shift = base + liveTune
            LyricsCache.shared.saveShift(base + liveTune, for: key)
            report = String(format: "%+.2fs (Shazam %+.2fs over %d match%@, fine-tuned %+.2fs by the aligner over %d readings, %@)",
                            base + liveTune, base, shazamSamples.count, shazamSamples.count == 1 ? "" : "es", liveTune, liveTunes.count, by)
            return
        }
        // A lock this song already has: a new measurement replaces it when it is a refinement of
        // it (within `agree`), otherwise the two are re-scored on the audio just decoded and the
        // one that fits THAT better wins — a chorus echoing a verse is a rival peak a line or two
        // away, and with enough audio behind the measurement the real lock stands out further than
        // the rival, which is what corrects a highlight that is parked a line out. Shazam's word
        // is never overruled by the aligner.
        if case .aligner(let held) = heldBy, let shift, abs(found.shift - shift) > Self.agree {
            let winner = LyricAligner.choose(held: LyricAligner.Alignment(shift: shift, confidence: held, margin: 0, lines: found.lines),
                                             heldShift: shift, candidate: found,
                                             lineTimes: times, songStart: songStart, onsets: onsets, agree: Self.agree)
            if winner.shift == shift {
                report = String(format: "kept %+.1fs; ignored %+.1fs (%@: scores %.3f vs %.3f on this audio)",
                                shift, found.shift, by,
                                LyricAligner.score(of: shift, lineTimes: times, songStart: songStart, onsets: onsets) ?? 0,
                                LyricAligner.score(of: found.shift, lineTimes: times, songStart: songStart, onsets: onsets) ?? 0) + shazam
                return
            }
            heldBy = .aligner(winner.confidence)
            self.shift = winner.shift
            lockedAt = songStart
            report = String(format: "%+.1fs (%@: moved from %+.1fs, scores %.3f vs %.3f, confidence %.1f)",
                            winner.shift, by, shift,
                            LyricAligner.score(of: winner.shift, lineTimes: times, songStart: songStart, onsets: onsets) ?? 0,
                            LyricAligner.score(of: shift, lineTimes: times, songStart: songStart, onsets: onsets) ?? 0,
                            winner.confidence) + shazam
            LyricsCache.shared.saveShift(winner.shift, for: key)
            return
        }
        heldBy = .aligner(found.confidence)
        shift = found.shift
        lockedAt = songStart
        report = String(format: "%+.1fs (%@: confidence %.1f, margin %.2f, %d lines, %.0fs of audio)",
                        found.shift, by, found.confidence, found.margin, found.lines, audio) + shazam
        LyricsCache.shared.saveShift(found.shift, for: key)
    }

    /// Whether a match says where in the record it was heard. Shazam names a song it has no timing
    /// for with an offset of zero, and an offset past the end of the lyrics (plus a minute for an
    /// outro) can't be this record either; trusting either throws every line out, so the caller
    /// stays on its fallback timing instead.
    public static func hasTiming(_ match: ShazamSync.Match, lyrics: Lyrics?) -> Bool {
        guard match.offset.isFinite, match.offset > 0.5 else { return false }
        guard let last = lyrics?.lines.compactMap(\.at).max() else { return true }
        return match.offset <= last + 60
    }

    /// Shazam heard the song on now: by the station's names, or by the names the lyrics were found
    /// under (Shazam's own, when the station's found nothing).
    public static func heard(_ match: ShazamSync.Match, key: String) -> Bool {
        if same(match, as: key) { return true }
        guard let lyrics = LyricsStore.shared.lyrics else { return false }
        return same(match, as: LyricsStore.key(lyrics.artist, lyrics.song))
    }

    /// Whether Shazam heard the song the lyrics are for (`key` is "artist|song", lowercased).
    /// Loose on purpose: the station says "Lose Yourself", Shazam "Lose Yourself (From "8 Mile")";
    /// the artist one way round or the other ("Eminem" / "Eminem & Dido").
    public static func same(_ match: ShazamSync.Match, as key: String) -> Bool {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        func plain(_ s: String) -> String {
            LyricsEngine.withoutParentheses(s).lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let (artist, song) = (plain(parts[0]), plain(parts[1]))
        let (heardArtist, heardSong) = (plain(match.artist), plain(match.title))
        guard !artist.isEmpty, !song.isEmpty, !heardArtist.isEmpty, !heardSong.isEmpty else { return false }
        return (heardSong.contains(song) || song.contains(heardSong))
            && (heardArtist.contains(artist) || artist.contains(heardArtist))
    }
}
