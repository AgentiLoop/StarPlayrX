//
//  Lyrics.swift
//  StarPlayrXMac
//
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  Lyrics for the song that's playing, from LRCLIB (https://lrclib.net) — free, open, no API key.
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
            status = cached == nil ? "No lyrics for this song on LRCLIB." : ""
            return
        }
        lyrics = nil
        status = "Searching LRCLIB…"
        task = Task {
            do {
                let found = try await Self.fetch(artist: artist, song: song, duration: duration)
                guard !Task.isCancelled, self.key == k else { return }
                self.cache[k] = found
                self.lyrics = found
                self.status = found == nil ? "No lyrics for this song on LRCLIB." : ""
            } catch is CancellationError {
            } catch {
                guard self.key == k else { return }
                self.lyrics = nil
                self.status = "Couldn't reach LRCLIB: \(error.localizedDescription)"
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
        let found = try await request("/api/search", [URLQueryItem(name: "track_name", value: song),
                                                     URLQueryItem(name: "artist_name", value: artist)])
        guard let records = found as? [[String: Any]], !records.isEmpty else { return nil }
        // Prefer a record with timestamps, and one whose artist really is this artist.
        let best = records.first { $0["syncedLyrics"] is String && matches(artist, $0) }
            ?? records.first { matches(artist, $0) }
            ?? records.first { $0["syncedLyrics"] is String }
            ?? records[0]
        return lyrics(from: best, artist: artist, song: song)
    }

    private static func matches(_ artist: String, _ record: [String: Any]) -> Bool {
        guard let name = record["artistName"] as? String else { return false }
        return name.localizedCaseInsensitiveContains(artist) || artist.localizedCaseInsensitiveContains(name)
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
                Text(store.lyrics.map { "\($0.song) · \($0.artist)" } ?? "LRCLIB")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Channels") { menu.lyrics = false }
                .help("Back to the channel list")
        }
        .frame(height: 22)
    }

    /// Synced lyrics scroll themselves and dim every line but the one being sung; plain lyrics
    /// are just a scrolling block of text.
    private func lines(_ lyrics: Lyrics) -> some View {
        // 0.25 s is close enough for a sung line and costs almost nothing to redraw.
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let at = radio.trackPosition
            let current = at.flatMap { Self.line(of: lyrics, at: $0) }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(lyrics.lines) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(line.id == current ? .body.bold() : .body)
                                .foregroundStyle(current == nil || line.id == current ? .primary : .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.trailing, 12)
                    .background(SkinnyScrollers().frame(width: 0, height: 0))
                }
                .frame(height: CachedArt<EmptyView>.listHeight)
                .padding(.trailing, -12)
                .onChange(of: current) { line in
                    guard let line else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(line, anchor: .center) }
                }
            }
        }
    }

    /// The last line whose timestamp has passed.
    static func line(of lyrics: Lyrics, at position: TimeInterval) -> Int? {
        guard lyrics.synced else { return nil }
        var found: Int?
        for line in lyrics.lines {
            guard let at = line.at, at <= position else { break }
            found = line.id
        }
        return found
    }
}
