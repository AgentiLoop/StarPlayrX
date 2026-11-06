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
    public static func line(of lyrics: Lyrics, at position: TimeInterval) -> Int? {
        guard lyrics.synced else { return nil }
        guard let last = lyrics.lines.last?.at, position < last + 30 else { return nil }
        var found: (id: Int, at: TimeInterval)?
        var next: TimeInterval?
        for line in lyrics.lines {
            guard let at = line.at else { continue }
            guard at <= position else { next = at; break }
            // Only a line the pane actually draws. LRC files time the gaps between verses as empty
            // lines, and `sections(of:)` drops those: asking the scroll view for an id it hasn't
            // got sends it to the bottom of the lyrics instead of to the line being sung.
            if !line.text.isEmpty { found = (line.id, at) }
        }
        guard let found else { return nil }
        // An instrumental (a solo, a long intro or break): nobody is singing, so nothing is lit.
        // A line stays lit for its first seconds; past that, with the next line still well away,
        // the highlight goes out until the singing comes back.
        if let next, next - found.at > instrumentalGap, position - found.at > lineHold { return nil }
        return found.id
    }

    /// A stretch between two timed lines longer than this is an instrumental, not a long line.
    public static let instrumentalGap: TimeInterval = 12
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
