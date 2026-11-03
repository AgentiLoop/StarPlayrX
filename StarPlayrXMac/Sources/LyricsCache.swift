//
//  LyricsCache.swift
//  StarPlayrXMac
//
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  Lyrics kept between launches in a SQLite file under Application Support, which belongs to the
//  app and needs no permission from anyone: ~/Library/Application Support/StarPlayrX/lyrics.sqlite
//  (sandboxed, that path is inside the container). A song looked up once is never fetched again,
//  so the lyrics servers see one request per song per Mac instead of one per tune-in.
//

import Foundation
import SQLite3

/// `sqlite3_bind_text` must copy the Swift string: it doesn't outlive the call.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class LyricsCache {
    static let shared = LyricsCache()

    /// A song that wasn't found anywhere is remembered too, so flipping back to it doesn't ask
    /// again — but only for a day, since a miss is often just a server having a bad minute.
    static let missLifetime: TimeInterval = 24 * 3600

    private var db: OpaquePointer?
    private let lock = NSLock()

    private init() {
        guard let folder = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            .appendingPathComponent("StarPlayrX", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("lyrics.sqlite")
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            db = nil
            return
        }
        // WAL: a reader never waits on the writer, and the file survives a hard quit mid-write.
        exec("PRAGMA journal_mode=WAL")
        exec("""
            CREATE TABLE IF NOT EXISTS lyrics (
                key TEXT PRIMARY KEY,
                artist TEXT NOT NULL,
                song TEXT NOT NULL,
                synced INTEGER NOT NULL,
                lines TEXT NOT NULL,
                fetched REAL NOT NULL)
            """)
        // Files written before the aligner existed have no `shift`; adding it fails harmlessly
        // once it is there.
        exec("ALTER TABLE lyrics ADD COLUMN shift REAL")
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// What the cache knows about this song: `.some(lyrics)` for a hit, `.some(nil)` for a miss
    /// that is still fresh, and nil when it has never been looked up (so go and fetch it).
    func lyrics(for key: String) -> Lyrics?? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT artist, song, synced, lines, fetched FROM lyrics WHERE key = ?", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let artist = String(cString: sqlite3_column_text(statement, 0))
        let song = String(cString: sqlite3_column_text(statement, 1))
        let synced = sqlite3_column_int(statement, 2) != 0
        let json = String(cString: sqlite3_column_text(statement, 3))
        let fetched = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
        let lines = Self.lines(from: json)
        if lines.isEmpty {
            // A remembered miss, kept only while it's fresh.
            return Date().timeIntervalSince(fetched) < Self.missLifetime ? .some(nil) : nil
        }
        return Lyrics(artist: artist, song: song, lines: lines, synced: synced)
    }

    /// Remembers what the search came back with, a miss included (as a row with no lines).
    func save(_ lyrics: Lyrics?, for key: String, artist: String, song: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO lyrics (key, artist, song, synced, lines, fetched) VALUES (?, ?, ?, ?, ?, ?)", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, transient)
        sqlite3_bind_text(statement, 2, lyrics?.artist ?? artist, -1, transient)
        sqlite3_bind_text(statement, 3, lyrics?.song ?? song, -1, transient)
        sqlite3_bind_int(statement, 4, lyrics?.synced == true ? 1 : 0)
        sqlite3_bind_text(statement, 5, Self.json(from: lyrics?.lines ?? []), -1, transient)
        sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
        sqlite3_step(statement)
    }

    /// The shift `LyricAligner` measured for this song last time it played, if any.
    func shift(for key: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT shift FROM lyrics WHERE key = ? AND shift IS NOT NULL", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_double(statement, 0)
    }

    /// Keeps the measured shift beside the words, so the song starts in step next time.
    func saveShift(_ shift: Double, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE lyrics SET shift = ? WHERE key = ?", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, shift)
        sqlite3_bind_text(statement, 2, key, -1, transient)
        sqlite3_step(statement)
    }

    /// How many songs are in the file (the About/diagnostics number, and what the tests check).
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return 0 }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM lyrics", -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
    }

    // MARK: Lines as JSON

    /// `[{"at": 11.07, "text": "…"}]`; a line with no timestamp has no `at`.
    static func json(from lines: [LyricLine]) -> String {
        let array = lines.map { line -> [String: Any] in
            line.at.map { ["at": $0, "text": line.text] } ?? ["text": line.text]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: array),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    static func lines(from json: String) -> [LyricLine] {
        guard let data = json.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return array.enumerated().map { LyricLine(id: $0.offset, at: $0.element["at"] as? TimeInterval,
                                                  text: $0.element["text"] as? String ?? "") }
    }
}
