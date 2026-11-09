//
//  LyricsLayout.swift
//  StarPlayrKit
//
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  How the lyrics views lay out and follow a song, shared by the Mac's LyricsPane and the iOS
//  LyricsView (moved out of LyricsPane unchanged).
//

import Foundation

public enum LyricsLayout {
    /// The lines grouped into sections, keeping every line's id (the highlight and the auto-scroll
    /// go by id). Blank lines are the breaks LRCLIB ships and are dropped; on synced lyrics more
    /// than 4 seconds between two lines is a break too (an intro, a solo, the gap before a chorus).
    public static func sections(of lyrics: Lyrics) -> [[LyricLine]] {
        var out = [[LyricLine]]()
        var section = [LyricLine]()
        var lastAt: TimeInterval?
        for line in lyrics.lines {
            let gap = line.at.flatMap { at in lastAt.map { at - $0 > 4 } } ?? false
            if (line.text.isEmpty || gap), !section.isEmpty {
                out.append(section)
                section = []
            }
            if let at = line.at { lastAt = at }
            guard !line.text.isEmpty else { continue }
            section.append(line)
        }
        if !section.isEmpty { out.append(section) }
        return out
    }

    /// `(Gold up in my teeth)` — a backing vocal, set apart from the line being sung.
    public static func isAdLib(_ text: String) -> Bool {
        text.count > 2 && text.hasPrefix("(") && text.hasSuffix(")")
    }

    /// The last line whose timestamp has passed. Nothing is highlighted before the first line or
    /// once the song has run well past the last one (a radio edit, or the wrong record): parking
    /// on the final line for minutes looks broken and is worse than no highlight at all.
    /// The stamps decide instrumentals (see `instrumental`); the sound classifier is not consulted,
    /// it mistakes a solo for singing.
    public static func line(of lyrics: Lyrics, at position: TimeInterval) -> Int? {
        guard lyrics.synced else { return nil }
        guard let last = lyrics.lines.last?.at, position < last + 30 else { return nil }
        guard let found = scan(lyrics, at: position) else { return nil }
        return found.instrumental ? nil : found.id
    }

    /// The last drawn line whose stamp has passed, and whether the song is in an instrumental after it.
    /// LRC files stamp an empty line where the singing stops, so once that stamp has passed and the
    /// next drawn line is a while off, that is an instrumental; without such a stamp, a long gap
    /// between two drawn lines is one (the line stays lit for its first seconds).
    private static func scan(_ lyrics: Lyrics, at position: TimeInterval) -> (id: Int, instrumental: Bool)? {
        var found: (id: Int, at: TimeInterval)?
        var ended: TimeInterval?      // the first empty stamp after `found`
        var next: TimeInterval?       // the next drawn line
        for line in lyrics.lines {
            guard let at = line.at else { continue }
            if at <= position {
                // Only a line the pane actually draws: asking the scroll view for an id it hasn't
                // got sends it to the bottom of the lyrics instead of to the line being sung.
                if !line.text.isEmpty { found = (line.id, at); ended = nil }
                else if found != nil, ended == nil { ended = at }
            } else if !line.text.isEmpty {
                next = at; break
            }
        }
        guard let found else { return nil }
        guard let next else { return (found.id, ended != nil) }   // after the last line: the outro
        if let ended, next - ended > breakGap { return (found.id, true) }
        return (found.id, next - found.at > instrumentalGap && position - found.at > lineHold)
    }

    /// The line being sung right now, for the views: the song's position against the stamps,
    /// against the stamps.
    @MainActor public static func line(of lyrics: Lyrics) -> Int? {
        position.flatMap { line(of: lyrics, at: $0) }
    }

    /// The line to light: the song's place against the stamps, or — only while the song's position
    /// isn't known at all — the line the user last tapped. Once the position is known, an instrumental
    /// lights nothing; an old tap never stands in for it.
    @MainActor public static func shown(in lyrics: Lyrics, tapped: Int?) -> Int? {
        position == nil ? tapped : line(of: lyrics)
    }

    /// Whether `position` falls in an instrumental stretch between two timed lines, where nobody
    /// is singing and nothing says how the stamps line up with the audio.
    public static func isInstrumental(_ lyrics: Lyrics, at position: TimeInterval) -> Bool {
        lyrics.synced && scan(lyrics, at: position)?.instrumental == true
    }

    /// A stretch between two timed lines longer than this is an instrumental, not a long line.
    public static let instrumentalGap: TimeInterval = 12
    /// After the empty stamp that ends a line, this much until the next line is an instrumental too.
    public static let breakGap: TimeInterval = 6
    /// How long a line stays lit into such a stretch.
    public static let lineHold: TimeInterval = 7

    /// `defaults write com.starplayrx.mac lyricsDisplayLead -float 0.3` moves it without a rebuild.
    public static var displayLead: TimeInterval {
        UserDefaults.standard.object(forKey: "lyricsDisplayLead") as? Double ?? 0
    }

    /// Where the lyrics treat the song as being: the track's position plus `displayLead`. No lead by
    /// default: with the position measured from the audio (Shazam) the highlight was running 0.3 s
    /// ahead of the singing, so the line lights on its own stamp.
    @MainActor public static var position: TimeInterval? {
        Radio.shared.trackPosition.map { $0 + displayLead }
    }

    /// The line the user clicked is the line being sung: the shift that makes the song's position
    /// land on that line's timestamp replaces whatever the aligner had worked out, and nothing
    /// measured later overrules it while this song plays. Live channels remember it for next time —
    /// that is the same correction the aligner saves — an Xtra track's position is the file's own,
    /// so its pin lasts only as long as the track does.
    @MainActor public static func pin(_ line: LyricLine, in lyrics: Lyrics, at position: TimeInterval?,
                                      showing: NowPlaying?) -> Bool {
        let radio = Radio.shared
        guard lyrics.synced, let target = line.at, let position, let np = showing else { return false }
        let live = radio.current?.xtraID == nil
        let key = LyricsStore.key(np.artist, np.song)
        let base = live ? (LyricSync.shared.shift(forKey: key) ?? Radio.liveLyricsLead)
                        : (LyricSync.shared.pinnedShift(forKey: key)
                           ?? radio.xtraNow.flatMap { LyricSync.shared.xtraShift(for: $0.file) } ?? 0)
        return LyricSync.shared.pin(shift: base + (target - position), forKey: key, remember: live)
    }

    /// A tap on a lyric line, in either app: pins timed lyrics there; returns the bubble to show, if any.
    @MainActor public static func tap(_ line: LyricLine, in lyrics: Lyrics) -> String? {
        guard lyrics.synced else { return "Text only lyrics, not timed" }
        return pin(line, in: lyrics, at: position, showing: Radio.shared.lyricsSong) ? "Lyrics position set" : nil
    }
}
