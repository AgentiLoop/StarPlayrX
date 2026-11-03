//
//  Lyrics.swift
//  StarPlayrXMac
//
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  Lyrics for the song that's playing, from LRCLIB (https://lrclib.net) — free, open, no API key
//  — falling back to NetEase and lyrics.ovh when LRCLIB is down or hasn't got the song.
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

/// One fetch per song, cached for the session. Misses are cached too, so flipping back to a song
/// LRCLIB doesn't have doesn't ask again.
@MainActor
final class LyricsStore: ObservableObject {
    static let shared = LyricsStore()

    @Published private(set) var lyrics: Lyrics?
    /// What to show when there are no lines: searching, not found, instrumental, or an error.
    @Published private(set) var status = ""

    private var key = ""
    private var cache = [String: Lyrics?]()
    private var task: Task<Void, Never>?

    private static func key(_ artist: String, _ song: String) -> String {
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
        if let cached = cache[k] {
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
                self.cache[k] = found
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

    /// LRCLIB first, then the backups, so a 503 or a missing record isn't the end of it:
    /// NetEase (timestamped, like LRCLIB) and then lyrics.ovh (plain text only).
    /// An error is only raised when every source failed — a plain miss everywhere is nil.
    private static func find(artist: String, song: String, duration: TimeInterval?) async throws -> Lyrics? {
        var failure: Error?
        for source in [fetch, netease, lyricsOVH] {
            do {
                if let found = try await source(artist, song, duration) { return found }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = error
            }
            try Task.checkCancellation()
        }
        if let failure { throw failure }
        return nil
    }

    /// `/api/get` first (the exact-match endpoint), then `/api/search` by title and artist for
    /// the live channels, whose song titles often don't match LRCLIB's exactly.
    private static func fetch(artist: String, song: String, duration: TimeInterval?) async throws -> Lyrics? {
        var get = [URLQueryItem(name: "track_name", value: song),
                   URLQueryItem(name: "artist_name", value: artist)]
        if let duration, duration >= 1, duration <= 3600 {
            get.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        if let record = try await request("/api/get", get) as? [String: Any] {
            return lyrics(from: record, artist: artist, song: song)
        }
        // The live channels tack a decade or a note onto the title ("Break Free (14)",
        // "All She Wants To Do Is Dance (85)"), which no LRCLIB record has. Ask again without it.
        let plainSong = withoutParentheses(song), plainArtist = withoutParentheses(artist)
        if plainSong != song || plainArtist != artist,
           let record = try await request("/api/get", [URLQueryItem(name: "track_name", value: plainSong),
                                                       URLQueryItem(name: "artist_name", value: plainArtist)]) as? [String: Any] {
            return lyrics(from: record, artist: artist, song: song)
        }
        let found = try await request("/api/search", [URLQueryItem(name: "track_name", value: plainSong),
                                                     URLQueryItem(name: "artist_name", value: plainArtist)])
        guard let records = found as? [[String: Any]], !records.isEmpty else { return nil }
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
        guard let best = mine.min(by: { gap($0, duration) < gap($1, duration) }),
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

    /// Seconds between a NetEase hit and the track we're playing; 0 when the length is unknown.
    private static func gap(_ hit: [String: Any], _ duration: TimeInterval?) -> TimeInterval {
        guard let duration, let ms = hit["duration"] as? Int else { return 0 }
        return abs(Double(ms) / 1000 - duration)
    }

    /// NetEase puts the writing credits ("作词 : …") in the first timestamped lines of the LRC.
    private static func isCredit(_ text: String) -> Bool {
        ["作词", "作曲", "编曲", "制作人", "混音", "录音"].contains { text.contains($0) }
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
    /// retrying — if one doesn't answer, the next source gets its turn.
    private static func json(_ url: URL) async throws -> Any? {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
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
                Text(store.lyrics.map { "\($0.song) · \($0.artist)" } ?? "LRCLIB · NetEase · lyrics.ovh")
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
                .onChange(of: current) { _, line in
                    guard let line else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(line, anchor: .center) }
                }
            }
        }
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
            found = line.id
        }
        return found
    }
}
