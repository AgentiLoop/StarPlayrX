//
//  Lyrics.swift
//  StarPlayrXMac
//
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  Lyrics for the song that's playing, from LRCLIB (https://lrclib.net) — free, open, no API key
//  — falling back to NetEase, QQ Music, Kugou and lyrics.ovh when LRCLIB is down or hasn't got
//  the song. Only the timestamped ones are worth caching; see LyricsStore.show.
//  Clicking the song/artist in Now Playing swaps the channel list for the lyrics (see MenuView).
//

import Foundation
import SwiftUI

// MARK: Model

public struct LyricLine: Identifiable {
    public let id: Int
    /// Seconds into the track; nil when the record only has plain (unsynced) lyrics.
    public let at: TimeInterval?
    public let text: String
    /// When each word starts, seconds into the track, where the source times every word (NetEase
    /// YRC, Kugou KRC, enhanced LRC `<mm:ss.xx>` tags). Empty otherwise. Only the aligner uses
    /// them: a word is another moment the voice arrives, many more of them than line starts.
    public var words: [TimeInterval] = []
}

public struct Lyrics {
    public let artist: String
    public let song: String
    public let lines: [LyricLine]
    /// True when every line has a timestamp, so the pane can follow the music.
    public let synced: Bool

    /// Whether this looks like a song's words at all. Sources sometimes answer with a stub — a
    /// single "probe" line, a credit, one word — which would sit in the pane instead of the
    /// lyrics. A song has at least a few lines and a couple dozen words.
    public var isReal: Bool {
        let sung = lines.map(\.text).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let words = sung.reduce(0) { $0 + $1.split(whereSeparator: \.isWhitespace).count }
        return sung.count >= 4 && words >= 20
    }

    /// Timed lyrics with a stretch of 45 s or more between one line and the next, before the
    /// last line: a part of the song the record never timed (often written up as "(...)"), so
    /// the pane sits on one line while the singing carries on. A guitar solo rarely runs that long.
    public var hasHole: Bool {
        let times = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.compactMap(\.at)
        return synced && zip(times, times.dropFirst()).contains { $1 - $0 >= 45 }
    }

    /// Typed in capitals from start to finish. Some sources keep a song in ALL CAPS, which shouts
    /// from the pane; a copy in ordinary case is looked for first, and `calmed` fixes it if none.
    public var isShouting: Bool {
        let letters = lines.flatMap { $0.text.unicodeScalars }.filter { CharacterSet.letters.contains($0) }
        let upper = letters.filter { CharacterSet.uppercaseLetters.contains($0) }.count
        let lower = letters.filter { CharacterSet.lowercaseLetters.contains($0) }.count
        return upper + lower >= 40 && Double(upper) / Double(upper + lower) > 0.8
    }

    /// The same lyrics in sentence case: each line starts with a capital, as does a bracket that
    /// opens one, and "I" (I'm, I'd, I'll, I've) stays a capital. Names lose theirs, which reads
    /// far better than a pane of capitals.
    public func calmed() -> Lyrics {
        guard isShouting else { return self }
        func calm(_ text: String) -> String {
            var out = ""
            var startOfLine = true
            for word in text.lowercased().split(separator: " ", omittingEmptySubsequences: false) {
                var w = String(word)
                // "i" on its own, whatever is round it: i, i'm, "i'd, (i, i,
                if let i = w.firstIndex(where: \.isLetter), w[i] == "i",
                   w[w.index(after: i)...].first.map({ !$0.isLetter }) ?? true {
                    w.replaceSubrange(i...i, with: "I")
                }
                if startOfLine || w.hasPrefix("("), let i = w.firstIndex(where: \.isLetter) {
                    w.replaceSubrange(i...i, with: w[i].uppercased())
                    startOfLine = false
                }
                out += (out.isEmpty ? "" : " ") + w
            }
            return out
        }
        return Lyrics(artist: artist, song: song,
                      lines: lines.map { LyricLine(id: $0.id, at: $0.at, text: calm($0.text), words: $0.words) },
                      synced: synced)
    }
}

/// An LRCLIB request that came back with something other than a record or a 404.
public struct LyricsError: LocalizedError {
    public let code: Int
    public var errorDescription: String? { "LRCLIB request failed (\(code))" }
}

// MARK: LRCLIB client

/// One fetch per song, ever: in memory for this run and in a SQLite file under Application Support
/// (`LyricsCache`) for every run after it. Misses are remembered too, for a day. Plain text is
/// shown but never kept, so a song that has only ever turned up as words is asked after again.
@MainActor
public class LyricsStore: ObservableObject {
    public static let shared = LyricsStore()

    @Published public private(set) var lyrics: Lyrics?
    /// What to show when there are no lines: searching, not found, instrumental, or an error.
    @Published public private(set) var status = ""
    /// The station's artist and title found nothing for the song on now. `LyricSync` then asks
    /// Shazam what is really playing and hands its names to `tryHeard`.
    public private(set) var missed = false

    private var key = ""
    /// The Shazam names last tried for this song, so each is only looked up once.
    private var heardKey = ""
    private var cache = [String: Lyrics?]()
    private var task: Task<Void, Never>?

    public static func key(_ artist: String, _ song: String) -> String {
        "\(artist.lowercased())|\(song.lowercased())"
    }

    /// Shows the lyrics for this song, fetching them the first time. Called on every now-playing
    /// change while the pane is open; repeat calls for the same song do nothing.
    public func show(artist: String, song: String, duration: TimeInterval?) {
        let k = Self.key(artist, song)
        guard k != key else { return }
        key = k
        heardKey = ""
        missed = false
        task?.cancel()
        guard !song.isEmpty else {
            lyrics = nil
            status = "Nothing playing."
            return
        }
        // A live take saved before those were turned away is looked up again rather than shown.
        if let cached = cache[k] ?? LyricsCache.shared.lyrics(for: k),
           !(cached.map { LyricsEngine.isOtherVersion($0.song, of: song) } ?? false) {
            cache[k] = cached
            lyrics = cached
            missed = cached == nil
            status = cached == nil ? "No lyrics found for this song." : ""
            return
        }
        lyrics = nil
        status = "Searching for lyrics…"
        task = Task {
            do {
                let found = try await Self.find(artist: artist, song: song, duration: duration)
                guard !Task.isCancelled, self.key == k else { return }
                // Only timestamped lyrics (and misses) are worth remembering. Plain text is what
                // was left when no LRC source had the song, and keeping it would stop every later
                // run from looking again for an LRC that may well have turned up since.
                if found?.synced ?? true {
                    self.cache[k] = found
                    // Kept in Application Support, so the next launch doesn't ask the servers again.
                    LyricsCache.shared.save(found, for: k, artist: artist, song: song)
                }
                self.lyrics = found
                self.missed = found == nil
                self.status = found == nil ? "No lyrics found for this song." : ""
            } catch is CancellationError {
            } catch {
                guard self.key == k else { return }
                self.lyrics = nil
                self.missed = true
                self.status = "Couldn't reach the lyrics servers: \(error.localizedDescription)"
            }
        }
    }

    /// The station's names found nothing: look again under the artist and title Shazam heard on
    /// air (the station's are often abbreviated, misspelled or a DJ's note). Lyrics found this way
    /// are kept under the station's names too, so the song loads straight away next time.
    public func tryHeard(artist: String, song: String, duration: TimeInterval?) {
        let k = key, heard = Self.key(artist, song)
        guard missed, !song.isEmpty, heard != k, heard != heardKey else { return }
        heardKey = heard
        let station = k.split(separator: "|", maxSplits: 1).map(String.init)
        func adopt(_ found: Lyrics?) {
            guard let found else {
                status = "No lyrics found for this song, nor for \"\(song)\" by \(artist) (Shazam)."
                return
            }
            lyrics = found
            missed = false
            status = ""
            if found.synced, station.count == 2 {
                cache[k] = found
                LyricsCache.shared.save(found, for: k, artist: station[0], song: station[1])
            }
        }
        if let cached = cache[heard] ?? LyricsCache.shared.lyrics(for: heard) {
            adopt(cached)
            return
        }
        task?.cancel()
        status = "Searching for lyrics for \"\(song)\" by \(artist) (Shazam)…"
        task = Task {
            let result: Lyrics??
            do { result = try await Self.find(artist: artist, song: song, duration: duration) } catch { result = nil }
            guard !Task.isCancelled, self.key == k, self.heardKey == heard else { return }
            // Every server failed: not a miss, so nothing is remembered.
            guard let found = result else { adopt(nil); return }
            if found?.synced ?? true {
                self.cache[heard] = found
                LyricsCache.shared.save(found, for: heard, artist: artist, song: song)
            }
            adopt(found)
        }
    }

    /// Forgets which song is shown, so re-opening the pane fetches/looks up again.
    public func reset() { key = "" }

    // MARK: Network

    private static let session = URLSession(configuration: .ephemeral)

    /// LRCLIB asks every client to name itself (and gives named clients a higher rate limit).
    private static let userAgent =
        "StarPlayrX \(AppVersion.string) (https://github.com/AgentiLoop/StarPlayrX)"

    /// One fetch of lyrics from every source in turn. The store overrides this in tests to serve
    /// canned lyrics, so a lookup round can be exercised with no network.
    /// One fetch of lyrics from every source in turn. The store overrides this in tests to serve
    /// canned lyrics, so a lookup round can be exercised with no network.
    public static func find(artist: String, song: String, duration: TimeInterval?) async throws -> Lyrics? {
        try await LyricsEngine.find(artist: artist, song: song, duration: duration)
    }
}

/// The search across all sources (LRCLIB, NetEase, QQ Music, Kugou, lyrics.ovh). Separate from
/// `LyricsStore` so tests can drive a full lookup through the store without any network.
public enum LyricsEngine {
    @MainActor private static let session = URLSession(configuration: .ephemeral)

    /// LRCLIB asks every client to name itself (and gives named clients a higher rate limit).
    private nonisolated static let userAgent =
        "StarPlayrX \(AppVersion.string) (https://github.com/AgentiLoop/StarPlayrX)"

    /// LRCLIB first, then the backups, so a 503 or a missing record isn't the end of it: three
    /// more LRC sources — NetEase, QQ Music and Kugou, timestamped like LRCLIB — and after them
    /// lyrics.ovh, which has only the words.
    /// An error is only raised when every source failed — a plain miss everywhere is nil.
    public static func find(artist: String, song: String, duration: TimeInterval?) async throws -> Lyrics? {
        var failure: Error?
        var plain: Lyrics?
        // Timed lyrics in ALL CAPS: kept in case nothing else turns up, but the next source gets
        // its turn to find the same song in ordinary case first.
        var shouting: Lyrics?
        for source in [fetch, netease, qqMusic, kugou, lyricsOVH] {
            do {
                if let found = try await source(artist, song, duration), found.isReal {
                    if found.synced, found.isShouting { shouting = shouting ?? found; continue }
                    // Timestamps win: a source that only has the words doesn't end the search, or a
                    // rate-limited LRCLIB would cost the whole song its highlight when the next
                    // source along has the same lyrics with times on them.
                    if found.synced { return found }
                    plain = plain ?? found
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = error
            }
            try Task.checkCancellation()
        }
        if let shouting { return shouting.calmed() }
        if let plain { return plain.calmed() }
        if let failure { throw failure }
        return nil
    }

    /// `/api/get` first (the exact-match endpoint), then `/api/search` by title and artist for
    /// the live channels, whose song titles often don't match LRCLIB's exactly.
    /// Each ask stands on its own: LRCLIB answers 503 "ServerOverloaded" whenever it feels like it,
    /// and one of those used to end this source's turn before the asks that had the song.
    private static func fetch(artist: String, song: String, duration: TimeInterval?) async throws -> Lyrics? {
        var failure: Error?
        func ask(_ path: String, _ query: [URLQueryItem]) async throws -> Any? {
            do { return try await request(path, query) }
            catch is CancellationError { throw CancellationError() }
            catch { failure = error; return nil }
        }
        var get = [URLQueryItem(name: "track_name", value: song),
                   URLQueryItem(name: "artist_name", value: artist)]
        if let duration, duration >= 1, duration <= 3600 {
            get.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        // An exact match whose timing has a hole in it (a minute and more with no line while the
        // record is still being sung, written up as "(...)") is kept only until the search turns
        // up a copy of the same song timed all the way through. LRCLIB's exact match for the Gap
        // Band's "You Dropped a Bomb On Me" skips 76 s of singing; four other records don't.
        var holed: Lyrics?
        // The exact match goes by length too, and a live take of about the same length is the answer
        // it gives (Anthology's "I Feel Fine" for a 135 s file): only the record itself is taken.
        if let record = try await ask("/api/get", get) as? [String: Any], !isOtherVersion(record, of: song),
           let got = lyrics(from: record, artist: artist, song: song) {
            guard got.hasHole || got.isShouting else { return got }
            holed = got
        }
        // The live channels tack a decade or a note onto the title ("Break Free (14)",
        // "All She Wants To Do Is Dance (85)"), which no LRCLIB record has. Ask again without it.
        let plainSong = withoutParentheses(song), plainArtist = withoutParentheses(artist)
        if holed == nil, plainSong != song || plainArtist != artist,
           let record = try await ask("/api/get", [URLQueryItem(name: "track_name", value: plainSong),
                                                   URLQueryItem(name: "artist_name", value: plainArtist)]) as? [String: Any],
           !isOtherVersion(record, of: song),
           let got = lyrics(from: record, artist: artist, song: song) {
            guard got.hasHole || got.isShouting else { return got }
            holed = got
        }
        let found = try await ask("/api/search", [URLQueryItem(name: "track_name", value: plainSong),
                                                  URLQueryItem(name: "artist_name", value: plainArtist)])
        guard let records = found as? [[String: Any]], !records.isEmpty else {
            if let holed { return holed }
            // Nothing from any of the three: a miss only if none of them was an error.
            if let failure { throw failure }
            return nil
        }
        // Only a record that really is this song. The search endpoint answers with whatever it has
        // (a search for Ed Sheeran's "Don't" came back as a Chinese song that happened to carry
        // timestamps), and the wrong lyrics are worse than none, so artist and title must both fit.
        let mine = records.filter { matches(plainArtist, $0) && isSong(plainSong, $0) && !isOtherVersion($0, of: song) }
        let timed = mine.filter { $0["syncedLyrics"] is String }.compactMap { lyrics(from: $0, artist: artist, song: song) }
        if let whole = timed.first(where: { $0.synced && !$0.hasHole && !$0.isShouting }) { return whole }
        if let holed { return holed }
        if let first = timed.first { return first }
        guard let best = mine.first else { return nil }
        return lyrics(from: best, artist: artist, song: song)
    }

    /// A live take, demo, remix… of the song, when the station's title doesn't ask for one: its
    /// words are the same but its timing isn't the record on air ("I Feel Fine" from Anthology 2
    /// sings its first line 4 s early and drifts from there). `name` and `album` are the hit's.
    public nonisolated static func isOtherVersion(_ name: String, album: String = "", of song: String) -> Bool {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter }.map(String.init))
        }
        let markers: Set<String> = ["live", "anthology", "demo", "acoustic", "remix", "karaoke", "unplugged",
                                    "rehearsal", "bbc", "outtake", "instrumental", "cover", "tribute"]
        let asked = words(song)
        return !markers.subtracting(asked).isDisjoint(with: words(name).union(words(album)))
    }

    private nonisolated static func isOtherVersion(_ record: [String: Any], of song: String) -> Bool {
        isOtherVersion(record["trackName"] as? String ?? "", album: record["albumName"] as? String ?? "", of: song)
    }

    /// The record's title is this song's, give or take the brackets either side carries.
    private static func isSong(_ song: String, _ record: [String: Any]) -> Bool {
        isSong(song, name: record["trackName"] as? String ?? "")
    }

    private static func isSong(_ song: String, name: String) -> Bool {
        let name = withoutParentheses(name)
        guard !name.isEmpty, !song.isEmpty else { return false }
        return name.localizedCaseInsensitiveContains(song) || song.localizedCaseInsensitiveContains(name)
    }

    // MARK: Backup engines

    /// NetEase Cloud Music: a search, then the lyric of the best hit. No key, and its records are
    /// timestamped like LRCLIB's, so a song LRCLIB hasn't got can still scroll with the music.
    private static func netease(artist: String, song: String, duration: TimeInterval?) async throws -> Lyrics? {
        let plainSong = withoutParentheses(song), plainArtist = withoutParentheses(artist)
        var search = URLComponents(string: "https://music.163.com/api/search/get")!
        search.queryItems = [URLQueryItem(name: "s", value: "\(plainSong) \(plainArtist)"),
                             URLQueryItem(name: "type", value: "1"),
                             URLQueryItem(name: "limit", value: "5")]
        guard let result = (try await json(search.url!) as? [String: Any])?["result"] as? [String: Any],
              let hits = result["songs"] as? [[String: Any]], !hits.isEmpty else { return nil }
        // Its search is loose enough to hand back covers and karaoke, so keep this artist's hits,
        // and of those take the one closest to the track's length.
        // Its search is loose enough to answer with a different song in a different language when
        // it has nothing close, so a hit has to be this artist's and carry this title. No hit that
        // fits means no lyrics from here; the next source gets its turn.
        let mine = hits.filter { hit in
            (hit["artists"] as? [[String: Any]] ?? []).contains { matches(plainArtist, name: $0["name"] as? String ?? "") }
                && isSong(plainSong, name: hit["name"] as? String ?? "")
                && !isOtherVersion(hit["name"] as? String ?? "",
                                   album: (hit["album"] as? [String: Any])?["name"] as? String ?? "", of: song)
        }
        guard let best = mine.min(by: { gap($0, "duration", 1000, duration) < gap($1, "duration", 1000, duration) }),
              let id = best["id"] as? Int else { return nil }
        var lyric = URLComponents(string: "https://music.163.com/api/song/lyric")!
        lyric.queryItems = [URLQueryItem(name: "id", value: String(id)),
                            URLQueryItem(name: "lv", value: "1"),
                            URLQueryItem(name: "tv", value: "-1"),
                            URLQueryItem(name: "yv", value: "1")]   // YRC: every word timed
        let record = try await json(lyric.url!) as? [String: Any]
        guard let lrc = record?["lrc"] as? [String: Any],
              let text = lrc["lyric"] as? String else { return nil }
        let yrc = (record?["yrc"] as? [String: Any])?["lyric"] as? String ?? ""
        let lines = withWords(timed(text).filter { !isCredit($0.text) }, from: yrc)
            .enumerated().map { LyricLine(id: $0.offset, at: $0.element.at, text: $0.element.text, words: $0.element.words) }
        guard !lines.isEmpty else { return nil }
        return Lyrics(artist: (best["artists"] as? [[String: Any]])?.first?["name"] as? String ?? artist,
                      song: best["name"] as? String ?? song, lines: lines, synced: true)
    }

    /// Seconds between a hit's length and the track we're playing; 0 when either is unknown.
    /// `key` is the field the source keeps the length in and `scale` what it counts in: NetEase
    /// milliseconds, QQ Music and Kugou whole seconds.
    private static func gap(_ hit: [String: Any], _ key: String, _ scale: Double,
                            _ duration: TimeInterval?) -> TimeInterval {
        guard let duration, let length = hit[key] as? Int else { return 0 }
        return abs(Double(length) / scale - duration)
    }

    /// NetEase puts the writing credits ("作词 : …") in the first timestamped lines of the LRC, and
    /// QQ Music and Kugou the same ("Lyrics by：…"), always on a fullwidth colon no lyric line
    /// would carry.
    private static func isCredit(_ text: String) -> Bool {
        text.contains("：") || ["作词", "作曲", "编曲", "制作人", "混音", "录音"].contains { text.contains($0) }
    }

    /// What QQ Music wants to see as the `Referer` before it parts with a lyric.
    private static let qq = "https://y.qq.com/"

    /// QQ Music: the same two steps as NetEase — a search, then the hit's LRC, timestamped, no key.
    /// A second synced source, for the songs NetEase hasn't got (and the days it won't answer).
    private static func qqMusic(artist: String, song: String, duration: TimeInterval?) async throws -> Lyrics? {
        let plainSong = withoutParentheses(song), plainArtist = withoutParentheses(artist)
        var search = URLComponents(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp")!
        search.queryItems = [URLQueryItem(name: "w", value: "\(plainSong) \(plainArtist)"),
                             URLQueryItem(name: "format", value: "json"),
                             URLQueryItem(name: "n", value: "5"),
                             URLQueryItem(name: "p", value: "1")]
        guard let data = (try await json(search.url!, referer: qq) as? [String: Any])?["data"] as? [String: Any],
              let hits = (data["song"] as? [String: Any])?["list"] as? [[String: Any]], !hits.isEmpty
        else { return nil }
        // Same guard as NetEase: its search answers with whatever it has, so a hit has to be this
        // artist's and carry this title, and of those the one closest to the track's length wins.
        let mine = hits.filter { hit in
            (hit["singer"] as? [[String: Any]] ?? []).contains { matches(plainArtist, name: $0["name"] as? String ?? "") }
                && isSong(plainSong, name: hit["songname"] as? String ?? "")
                && !isOtherVersion(hit["songname"] as? String ?? "", album: hit["albumname"] as? String ?? "", of: song)
        }
        guard let best = mine.min(by: { gap($0, "interval", 1, duration) < gap($1, "interval", 1, duration) }),
              let mid = best["songmid"] as? String else { return nil }
        var lyric = URLComponents(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!
        lyric.queryItems = [URLQueryItem(name: "songmid", value: mid),
                            URLQueryItem(name: "format", value: "json"),
                            URLQueryItem(name: "nobase64", value: "1")]
        // A song it has no words for comes back 200 with a retcode and no `lyric` — same as a miss.
        guard let text = (try await json(lyric.url!, referer: qq) as? [String: Any])?["lyric"] as? String else { return nil }
        let lines = lrcLines(text)
        guard !lines.isEmpty else { return nil }
        return Lyrics(artist: (best["singer"] as? [[String: Any]])?.first?["name"] as? String ?? artist,
                      song: best["songname"] as? String ?? song, lines: lines, synced: true)
    }

    /// Kugou: the third timestamped source, in three steps — find the recording, ask which lyric
    /// goes with it, download that. Its search matches one field at a time, so the keyword is the
    /// title on its own and the artist is matched against the hits, as with the other two.
    private static func kugou(artist: String, song: String, duration: TimeInterval?) async throws -> Lyrics? {
        let plainSong = withoutParentheses(song), plainArtist = withoutParentheses(artist)
        var search = URLComponents(string: "https://songsearch.kugou.com/song_search_v2")!
        search.queryItems = [URLQueryItem(name: "keyword", value: plainSong),
                             URLQueryItem(name: "page", value: "1"),
                             URLQueryItem(name: "pagesize", value: "20")]
        guard let data = (try await json(search.url!) as? [String: Any])?["data"] as? [String: Any],
              let hits = data["lists"] as? [[String: Any]], !hits.isEmpty else { return nil }
        let mine = hits.filter { hit in
            matches(plainArtist, name: hit["SingerName"] as? String ?? "")
                && isSong(plainSong, name: hit["SongName"] as? String ?? "")
                && !isOtherVersion(hit["SongName"] as? String ?? "", album: hit["AlbumName"] as? String ?? "", of: song)
        }
        guard let best = mine.min(by: { gap($0, "Duration", 1, duration) < gap($1, "Duration", 1, duration) }),
              let hash = best["FileHash"] as? String, let length = best["Duration"] as? Int else { return nil }
        // Which lyric goes with the recording is a question about the recording, not the words:
        // the file's hash and length are the whole query, and the live version of a song gets the
        // live version's timings.
        var candidates = URLComponents(string: "https://krcs.kugou.com/search")!
        candidates.queryItems = [URLQueryItem(name: "ver", value: "1"),
                                 URLQueryItem(name: "man", value: "yes"),
                                 URLQueryItem(name: "client", value: "mobi"),
                                 URLQueryItem(name: "duration", value: String(length * 1000)),
                                 URLQueryItem(name: "hash", value: hash)]
        guard let list = (try await json(candidates.url!) as? [String: Any])?["candidates"] as? [[String: Any]],
              let pick = list.first, let id = pick["id"] as? String,
              let accessKey = pick["accesskey"] as? String else { return nil }
        var download = URLComponents(string: "https://lyrics.kugou.com/download")!
        download.queryItems = [URLQueryItem(name: "ver", value: "1"),
                               URLQueryItem(name: "client", value: "pc"),
                               URLQueryItem(name: "id", value: id),
                               URLQueryItem(name: "accesskey", value: accessKey),
                               URLQueryItem(name: "fmt", value: "lrc"),
                               URLQueryItem(name: "charset", value: "utf8")]
        // Even asked for as an LRC, the words come back Base64'd.
        guard let encoded = (try await json(download.url!) as? [String: Any])?["content"] as? String,
              let decoded = Data(base64Encoded: encoded),
              let text = String(data: decoded, encoding: .utf8) else { return nil }
        var lines = lrcLines(text)
        guard !lines.isEmpty else { return nil }
        // The same lyric as a KRC times every word. Worth one more ask, but only a bonus: the LRC
        // above is the answer whether this works or not.
        download.queryItems?.removeAll { $0.name == "fmt" }
        download.queryItems?.append(URLQueryItem(name: "fmt", value: "krc"))
        if let encoded = (try? await json(download.url!) as? [String: Any])?["content"] as? String,
           let krc = decryptKRC(encoded) {
            lines = withWords(lines, from: krc)
        }
        return Lyrics(artist: best["SingerName"] as? String ?? artist,
                      song: best["SongName"] as? String ?? song, lines: lines, synced: true)
    }

    /// The words out of a QQ Music or Kugou LRC, which both open with their own
    /// "<song> - <artist>" header on the song's first instant, then the writing credits.
    private static func lrcLines(_ text: String) -> [LyricLine] {
        var lines = timed(text).filter { !isCredit($0.text) }
        if let first = lines.first, (first.at ?? 0) < 1, first.text.contains(" - ") { lines.removeFirst() }
        return lines.enumerated().map { LyricLine(id: $0.offset, at: $0.element.at, text: $0.element.text, words: $0.element.words) }
    }

    /// Word-timed lyrics, NetEase YRC and Kugou KRC, as (line start, word starts) in seconds. Both
    /// open a line with `[startMs,durationMs]`; YRC then gives each word as `(absoluteMs,dur,0)`,
    /// KRC as `<msIntoLine,dur,0>`. Metadata and JSON credit lines have no such opening.
    public static func wordTimed(_ text: String) -> [(at: TimeInterval, words: [TimeInterval])] {
        var out = [(at: TimeInterval, words: [TimeInterval])]()
        for raw in text.components(separatedBy: .newlines) {
            guard raw.hasPrefix("["), let close = raw.firstIndex(of: "]") else { continue }
            let head = raw[raw.index(after: raw.startIndex)..<close].split(separator: ",")
            guard head.count == 2, let start = Double(head[0]) else { continue }
            var words = [TimeInterval]()
            var rest = raw[raw.index(after: close)...]
            while let open = rest.firstIndex(where: { $0 == "(" || $0 == "<" }) {
                let shut: Character = rest[open] == "(" ? ")" : ">"
                guard let end = rest[open...].firstIndex(of: shut) else { break }
                let fields = rest[rest.index(after: open)..<end].split(separator: ",")
                if fields.count == 3, let ms = Double(fields[0]) {
                    words.append((shut == ")" ? ms : start + ms) / 1000)
                }
                rest = rest[rest.index(after: end)...]
            }
            if !words.isEmpty { out.append((start / 1000, words)) }
        }
        return out
    }

    /// Hangs the word times of a YRC/KRC on the LRC lines they belong to: the word-timed line that
    /// starts within a second of the LRC line's stamp. Lines with no partner keep what they had.
    public static func withWords(_ lines: [LyricLine], from text: String) -> [LyricLine] {
        let timed = wordTimed(text)
        guard !timed.isEmpty else { return lines }
        return lines.map { line in
            guard let at = line.at,
                  let match = timed.min(by: { abs($0.at - at) < abs($1.at - at) }), abs(match.at - at) < 1
            else { return line }
            return LyricLine(id: line.id, at: line.at, text: line.text, words: match.words)
        }
    }

    /// Kugou's KRC: Base64 of "krc1" + a zlib stream XORed with a fixed 16-byte key.
    public static func decryptKRC(_ base64: String) -> String? {
        let key: [UInt8] = [0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69]
        guard let data = Data(base64Encoded: base64), data.count > 6, data.prefix(4) == Data("krc1".utf8) else { return nil }
        let plain = Data(data.dropFirst(4).enumerated().map { $0.element ^ key[$0.offset % key.count] })
        // Foundation's .zlib is raw DEFLATE: skip the two-byte zlib header.
        guard let inflated = try? (plain.dropFirst(2) as NSData).decompressed(using: .zlib) as Data else { return nil }
        return String(data: inflated, encoding: .utf8)
    }

    /// lyrics.ovh: plain text only, no timestamps, but it has songs the other two don't. Last resort.
    private static func lyricsOVH(artist: String, song: String, duration: TimeInterval?) async throws -> Lyrics? {
        let escape = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text }
        let plainSong = withoutParentheses(song), plainArtist = withoutParentheses(artist)
        guard let url = URL(string: "https://api.lyrics.ovh/v1/\(escape(plainArtist))/\(escape(plainSong))"),
              let text = (try await json(url) as? [String: Any])?["lyrics"] as? String else { return nil }
        let lines = text.components(separatedBy: .newlines).enumerated()
            .map { LyricLine(id: $0.offset, at: nil, text: $0.element.trimmingCharacters(in: .whitespaces)) }
        guard lines.contains(where: { !$0.text.isEmpty }) else { return nil }
        return Lyrics(artist: artist, song: song, lines: lines, synced: false)
    }

    /// Decoded JSON, or nil on anything but a 200. The backups have no error contract worth
    /// retrying — if one doesn't answer, the next source gets its turn. QQ Music hands back an
    /// error code instead of the words unless the request says it came from its own site.
    private static func json(_ url: URL, referer: String? = nil) async throws -> Any? {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// "Break Free (14)" -> "Break Free". Everything in brackets goes, and so do the spaces it
    /// leaves behind. A title that is nothing but brackets is kept as it was, so the search
    /// still has something to go on.
    public nonisolated static func withoutParentheses(_ text: String) -> String {
        var out = ""
        var depth = 0
        for c in text {
            switch c {
            case "(", "[": depth += 1
            case ")", "]": depth = max(0, depth - 1)
            default: if depth == 0 { out.append(c) }
            }
        }
        let trimmed = out.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? text : trimmed
    }

    public static func matches(_ artist: String, _ record: [String: Any]) -> Bool {
        guard let name = record["artistName"] as? String else { return false }
        return matches(artist, name: name)
    }

    public static func matches(_ artist: String, name: String) -> Bool {
        !name.isEmpty && (name.localizedCaseInsensitiveContains(artist) || artist.localizedCaseInsensitiveContains(name))
    }

    /// The decoded JSON, or nil on 404 (no record). Honors `Retry-After` once on 429/503.
    private static func request(_ path: String, _ query: [URLQueryItem]) async throws -> Any? {
        var components = URLComponents(string: "https://lrclib.net" + path)!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        for attempt in 0...1 {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200: return try JSONSerialization.jsonObject(with: data)
            case 404: return nil
            case 429, 503:
                let after = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                guard attempt == 0 else { throw LyricsError(code: code) }
                // Jitter, as LRCLIB asks, so throttled clients don't all retry at once.
                let wait = (Double(after ?? "") ?? 1) * (1 + Double.random(in: 0...0.3))
                try await Task.sleep(nanoseconds: UInt64(min(wait, 10) * 1_000_000_000))
            default: throw LyricsError(code: code)
            }
        }
        return nil
    }

    // MARK: Parsing

    private static func lyrics(from record: [String: Any], artist: String, song: String) -> Lyrics? {
        let shownArtist = record["artistName"] as? String ?? artist
        let shownSong = record["trackName"] as? String ?? song
        if record["instrumental"] as? Bool == true {
            return Lyrics(artist: shownArtist, song: shownSong,
                          lines: [LyricLine(id: 0, at: nil, text: "♪ Instrumental ♪")], synced: false)
        }
        if let lrc = record["syncedLyrics"] as? String {
            let lines = timed(lrc)
            if !lines.isEmpty { return Lyrics(artist: shownArtist, song: shownSong, lines: lines, synced: true) }
        }
        guard let plain = record["plainLyrics"] as? String else { return nil }
        let lines = plain.components(separatedBy: .newlines).enumerated()
            .map { LyricLine(id: $0.offset, at: nil, text: $0.element.trimmingCharacters(in: .whitespaces)) }
        return lines.contains { !$0.text.isEmpty }
            ? Lyrics(artist: shownArtist, song: shownSong, lines: lines, synced: false) : nil
    }

    /// LRC: `[mm:ss.xx] text`, one or more timestamps per line. Metadata tags (`[ar:…]`) have no
    /// digits where the minutes go and are dropped.
    public static func timed(_ lrc: String) -> [LyricLine] {
        var out = [(TimeInterval, String, [TimeInterval])]()
        for raw in lrc.components(separatedBy: .newlines) {
            var rest = Substring(raw)
            var stamps = [TimeInterval]()
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                let parts = tag.split(separator: ":")
                guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { break }
                stamps.append(minutes * 60 + seconds)
                rest = rest[rest.index(after: close)...]
            }
            guard !stamps.isEmpty else { continue }
            // Enhanced LRC: `<mm:ss.xx>` before each word. Taken out of the text, kept as word times
            // relative to the line, so a line stamped more than once gets them at every stamp.
            var words = [TimeInterval]()
            var plain = ""
            while let open = rest.firstIndex(of: "<") {
                plain += rest[..<open]
                guard let close = rest[open...].firstIndex(of: ">") else { break }
                let parts = rest[rest.index(after: open)..<close].split(separator: ":")
                if parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) {
                    // Word times are relative to the line's FIRST stamp; each later stamp of the same
                    // (repeated) line offsets them by that stamp, not by the first.
                    words.append(minutes * 60 + seconds - stamps[0])
                } else {
                    plain += rest[open...close]
                }
                rest = rest[rest.index(after: close)...]
            }
            plain += rest
            let text = plain.trimmingCharacters(in: .whitespaces)
            for (_, base) in stamps.enumerated() { out.append((base, text, words.map { $0 + (base - stamps[0]) })) }
        }
        return out.sorted { $0.0 < $1.0 }.enumerated().map {
            LyricLine(id: $0.offset, at: $0.element.0, text: $0.element.1, words: $0.element.2)
        }
    }
}
