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

struct LyricLine: Identifiable {
    let id: Int
    /// Seconds into the track; nil when the record only has plain (unsynced) lyrics.
    let at: TimeInterval?
    let text: String
}

struct Lyrics {
    let artist: String
    let song: String
    let lines: [LyricLine]
    /// True when every line has a timestamp, so the pane can follow the music.
    let synced: Bool
}

/// An LRCLIB request that came back with something other than a record or a 404.
struct LyricsError: LocalizedError {
    let code: Int
    var errorDescription: String? { "LRCLIB request failed (\(code))" }
}

// MARK: LRCLIB client

/// One fetch per song, ever: in memory for this run and in a SQLite file under Application Support
/// (`LyricsCache`) for every run after it. Misses are remembered too, for a day. Plain text is
/// shown but never kept, so a song that has only ever turned up as words is asked after again.
@MainActor
final class LyricsStore: ObservableObject {
    static let shared = LyricsStore()

    @Published private(set) var lyrics: Lyrics?
    /// What to show when there are no lines: searching, not found, instrumental, or an error.
    @Published private(set) var status = ""

    private var key = ""
    private var cache = [String: Lyrics?]()
    private var task: Task<Void, Never>?

    static func key(_ artist: String, _ song: String) -> String {
        "\(artist.lowercased())|\(song.lowercased())"
    }

    /// Shows the lyrics for this song, fetching them the first time. Called on every now-playing
    /// change while the pane is open; repeat calls for the same song do nothing.
    func show(artist: String, song: String, duration: TimeInterval?) {
        let k = Self.key(artist, song)
        guard k != key else { return }
        key = k
        task?.cancel()
        guard !song.isEmpty else {
            lyrics = nil
            status = "Nothing playing."
            return
        }
        if let cached = cache[k] ?? LyricsCache.shared.lyrics(for: k) {
            cache[k] = cached
            lyrics = cached
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
                self.status = found == nil ? "No lyrics found for this song." : ""
            } catch is CancellationError {
            } catch {
                guard self.key == k else { return }
                self.lyrics = nil
                self.status = "Couldn't reach the lyrics servers: \(error.localizedDescription)"
            }
        }
    }

    /// Forgets which song is shown, so re-opening the pane fetches/looks up again.
    func reset() { key = "" }

    // MARK: Network

    private static let session = URLSession(configuration: .ephemeral)

    /// LRCLIB asks every client to name itself (and gives named clients a higher rate limit).
    private static let userAgent =
        "StarPlayrX \(MenuView.version) (https://github.com/AgentiLoop/StarPlayrX)"

    /// LRCLIB first, then the backups, so a 503 or a missing record isn't the end of it: three
    /// more LRC sources — NetEase, QQ Music and Kugou, timestamped like LRCLIB — and after them
    /// lyrics.ovh, which has only the words.
    /// An error is only raised when every source failed — a plain miss everywhere is nil.
    private static func find(artist: String, song: String, duration: TimeInterval?) async throws -> Lyrics? {
        var failure: Error?
        var plain: Lyrics?
        for source in [fetch, netease, qqMusic, kugou, lyricsOVH] {
            do {
                if let found = try await source(artist, song, duration) {
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
        if let plain { return plain }
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
        if let record = try await ask("/api/get", get) as? [String: Any] {
            return lyrics(from: record, artist: artist, song: song)
        }
        // The live channels tack a decade or a note onto the title ("Break Free (14)",
        // "All She Wants To Do Is Dance (85)"), which no LRCLIB record has. Ask again without it.
        let plainSong = withoutParentheses(song), plainArtist = withoutParentheses(artist)
        if plainSong != song || plainArtist != artist,
           let record = try await ask("/api/get", [URLQueryItem(name: "track_name", value: plainSong),
                                                   URLQueryItem(name: "artist_name", value: plainArtist)]) as? [String: Any] {
            return lyrics(from: record, artist: artist, song: song)
        }
        let found = try await ask("/api/search", [URLQueryItem(name: "track_name", value: plainSong),
                                                  URLQueryItem(name: "artist_name", value: plainArtist)])
        guard let records = found as? [[String: Any]], !records.isEmpty else {
            // Nothing from any of the three: a miss only if none of them was an error.
            if let failure { throw failure }
            return nil
        }
        // Only a record that really is this song. The search endpoint answers with whatever it has
        // (a search for Ed Sheeran's "Don't" came back as a Chinese song that happened to carry
        // timestamps), and the wrong lyrics are worse than none, so artist and title must both fit.
        let best = records.first { $0["syncedLyrics"] is String && matches(plainArtist, $0) && isSong(plainSong, $0) }
            ?? records.first { matches(plainArtist, $0) && isSong(plainSong, $0) }
        guard let best else { return nil }
        return lyrics(from: best, artist: artist, song: song)
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
        }
        guard let best = mine.min(by: { gap($0, "duration", 1000, duration) < gap($1, "duration", 1000, duration) }),
              let id = best["id"] as? Int else { return nil }
        var lyric = URLComponents(string: "https://music.163.com/api/song/lyric")!
        lyric.queryItems = [URLQueryItem(name: "id", value: String(id)),
                            URLQueryItem(name: "lv", value: "1"),
                            URLQueryItem(name: "tv", value: "-1")]
        guard let lrc = (try await json(lyric.url!) as? [String: Any])?["lrc"] as? [String: Any],
              let text = lrc["lyric"] as? String else { return nil }
        let lines = timed(text).filter { !isCredit($0.text) }
            .enumerated().map { LyricLine(id: $0.offset, at: $0.element.at, text: $0.element.text) }
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
        let lines = lrcLines(text)
        guard !lines.isEmpty else { return nil }
        return Lyrics(artist: best["SingerName"] as? String ?? artist,
                      song: best["SongName"] as? String ?? song, lines: lines, synced: true)
    }

    /// The words out of a QQ Music or Kugou LRC, which both open with their own
    /// "<song> - <artist>" header on the song's first instant, then the writing credits.
    private static func lrcLines(_ text: String) -> [LyricLine] {
        var lines = timed(text).filter { !isCredit($0.text) }
        if let first = lines.first, (first.at ?? 0) < 1, first.text.contains(" - ") { lines.removeFirst() }
        return lines.enumerated().map { LyricLine(id: $0.offset, at: $0.element.at, text: $0.element.text) }
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
    nonisolated static func withoutParentheses(_ text: String) -> String {
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

    private static func matches(_ artist: String, _ record: [String: Any]) -> Bool {
        guard let name = record["artistName"] as? String else { return false }
        return matches(artist, name: name)
    }

    private static func matches(_ artist: String, name: String) -> Bool {
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
    static func timed(_ lrc: String) -> [LyricLine] {
        var out = [(TimeInterval, String)]()
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
            let text = rest.trimmingCharacters(in: .whitespaces)
            for at in stamps { out.append((at, text)) }
        }
        return out.sorted { $0.0 < $1.0 }.enumerated().map { LyricLine(id: $0.offset, at: $0.element.0, text: $0.element.1) }
    }
}

// MARK: Pane

/// Takes the channel list's place, same height, so the panel doesn't change size.
struct LyricsPane: View {
    @EnvironmentObject var radio: Radio
    @ObservedObject private var menu = MenuController.shared
    @ObservedObject private var store = LyricsStore.shared
    @State private var tipLine: Int?
    @State private var tipTask: Task<Void, Never>?

    /// The song the pane is about: what's coming out of the speakers, else what the row shows.
    private var showing: NowPlaying? {
        radio.playingNow ?? radio.current.flatMap { radio.nowPlaying[$0.id] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let lyrics = store.lyrics {
                lines(lyrics)
            } else {
                VStack {
                    Spacer()
                    Text(store.status).font(.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 20)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .frame(height: CachedArt<EmptyView>.listHeight)
            }
        }
        // Follows the song: a new title (or opening the pane) starts the fetch.
        .task(id: "\(showing?.artist ?? "")|\(showing?.song ?? "")") {
            store.show(artist: showing?.artist ?? "", song: showing?.song ?? "", duration: radio.trackDuration)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Lyrics").font(.headline)
                // Plain lyrics say so in place of the title: nothing will scroll, and that's why.
                Text(store.lyrics.map { $0.synced ? "\($0.song) · \($0.artist)"
                                                  : "Text only lyrics - sync not available" }
                     ?? "LRCLIB · NetEase · QQ · Kugou")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Channels") { menu.lyrics = false }
                .help("Back to the channel list")
        }
        .frame(height: 22)
    }

    /// Synced lyrics scroll themselves and dim every line but the one being sung; plain lyrics
    /// are just a scrolling block of text. Either way the lines are grouped into sections, so
    /// verses and the chorus read apart instead of as one wall of text.
    private func lines(_ lyrics: Lyrics) -> some View {
        // 0.25 s is close enough for a sung line and costs almost nothing to redraw.
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let _ = measure(lyrics)
            let at = radio.trackPosition
            let current = at.flatMap { Self.line(of: lyrics, at: $0) }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Self.sections(of: lyrics), id: \.first!.id) { section in
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(section) { line in
                                    let adLib = Self.isAdLib(line.text)
                                    Text(line.text)
                                        .font(line.id == current ? .body.bold() : adLib ? .callout : .body)
                                        .foregroundStyle(current == nil || line.id == current ? .primary : .secondary)
                                        .padding(.leading, adLib ? 14 : 0)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        // Click a line to say that is what is being sung right now:
                                        // the highlight moves there and the rest of the song follows
                                        // from it. Only means anything on timed lyrics.
                                        .contentShape(Rectangle())
                                        .onTapGesture { pin(line, in: lyrics, at: at) }
                                        // A system .help tooltip can't be timed, so this one is drawn here
                                        // and goes away 3 seconds after it appears.
                                        .onHover { inside in
                                            tipTask?.cancel()
                                            guard inside, lyrics.synced else { tipLine = nil; return }
                                            tipTask = Task { @MainActor in
                                                try? await Task.sleep(nanoseconds: 700_000_000)
                                                guard !Task.isCancelled else { return }
                                                tipLine = line.id
                                                try? await Task.sleep(nanoseconds: 3_000_000_000)
                                                guard !Task.isCancelled else { return }
                                                tipLine = nil
                                            }
                                        }
                                        .overlay {
                                            if tipLine == line.id {
                                                Text("Click the line being sung to sync the lyrics")
                                                    .font(.caption).padding(5)
                                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                                                    .fixedSize().allowsHitTesting(false)
                                            }
                                        }
                                        .id(line.id)
                                }

                            }
                        }
                    }
                    .padding(.trailing, 12)
                    .background(SkinnyScrollers().frame(width: 0, height: 0))
                }
                .frame(height: CachedArt<EmptyView>.listHeight)
                .padding(.trailing, -12)
                .onValueChange(of: current) { line in
                    guard let line else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(line, anchor: .center) }
                }
            }
        }
    }

    /// Hands the aligner a turn on every tick; it measures at most every 15 seconds, and only on
    /// a live channel, where the cut's stamp is what the position is worked out from.
    private func measure(_ lyrics: Lyrics) {
        guard let channel = radio.current, channel.xtraID == nil,
              let np = radio.nowPlaying[channel.id], let started = np.startedAt else { return }
        LyricSync.shared.update(lyrics: lyrics, key: LyricsStore.key(np.artist, np.song), songStart: started)
    }

    /// The line the user clicked is the line being sung: the shift that makes the song's position
    /// land on that line's timestamp replaces whatever the aligner had worked out, and nothing
    /// measured later overrules it while this song plays. Live channels remember it for next time —
    /// that is the same correction the aligner saves — an Xtra track's position is the file's own,
    /// so its pin lasts only as long as the track does.
    private func pin(_ line: LyricLine, in lyrics: Lyrics, at position: TimeInterval?) {
        guard lyrics.synced, let target = line.at, let position, let np = showing else { return }
        let live = radio.current?.xtraID == nil
        let key = LyricsStore.key(np.artist, np.song)
        let base = live ? (LyricSync.shared.shift(forKey: key) ?? Radio.liveLyricsLead)
                        : (LyricSync.shared.pinnedShift(forKey: key) ?? 0)
        LyricSync.shared.pin(shift: base + (target - position), forKey: key, remember: live)
    }


    /// The lines grouped into sections, keeping every line's id (the highlight and the auto-scroll
    /// go by id). Blank lines are the breaks LRCLIB ships and are dropped; on synced lyrics more
    /// than 4 seconds between two lines is a break too (an intro, a solo, the gap before a chorus).
    static func sections(of lyrics: Lyrics) -> [[LyricLine]] {
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
    static func isAdLib(_ text: String) -> Bool {
        text.count > 2 && text.hasPrefix("(") && text.hasSuffix(")")
    }

    /// The last line whose timestamp has passed. Nothing is highlighted before the first line or
    /// once the song has run well past the last one (a radio edit, or the wrong record): parking
    /// on the final line for minutes looks broken and is worse than no highlight at all.
    static func line(of lyrics: Lyrics, at position: TimeInterval) -> Int? {
        guard lyrics.synced else { return nil }
        guard let last = lyrics.lines.last?.at, position < last + 30 else { return nil }
        var found: Int?
        for line in lyrics.lines {
            guard let at = line.at, at <= position else { break }
            // Only a line the pane actually draws. LRC files time the gaps between verses as empty
            // lines, and `sections(of:)` drops those: asking the scroll view for an id it hasn't
            // got sends it to the bottom of the lyrics instead of to the line being sung.
            if !line.text.isEmpty { found = line.id }
        }
        return found
    }
}

/// `onChange` that hands over just the new value. The one-parameter form is deprecated in
/// macOS 14 and the two-parameter one doesn't exist before it, and the app runs on macOS 13.
private extension View {
    @ViewBuilder
    func onValueChange<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        if #available(macOS 14, *) {
            onChange(of: value) { _, new in action(new) }
        } else {
            legacyOnChange(of: value, perform: action)
        }
    }

    /// Deprecated itself, so the macOS 13 fallback doesn't warn about the API it has to use.
    @available(macOS, deprecated: 14.0)
    func legacyOnChange<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        onChange(of: value, perform: action)
    }
}

extension LyricsPane {
    /// The tests reach the aligner through the pane, which is where it is used.
    static func alignment(lineTimes: [Double], songStart: Date,
                          onsets: (start: Date, step: Double, values: [Float])) -> LyricAligner.Alignment? {
        LyricAligner.align(lineTimes: lineTimes, songStart: songStart, onsets: onsets)
    }
}
