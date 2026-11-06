//
//  Models.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  The small value types the app passes around: channels, what's playing, Xtra tracks, errors.

import Foundation

// MARK: Channels (Radio)

public struct Channel: Identifiable, Hashable {
    public let id: String          // channel number
    public let name: String
    public let category: String
    public let imageURL: String
    public var xtraID: String? = nil   // set for Xtra channels (streamed track by track)

    public init(id: String, name: String, category: String, imageURL: String, xtraID: String? = nil) {
        self.id = id; self.name = name; self.category = category; self.imageURL = imageURL; self.xtraID = xtraID
    }
}

public struct NowPlaying: Equatable {
    public var artist = ""
    public var song = ""
    public var image = ""
    /// The show's artwork (often a text title card), shown instead of the channel logo only when the
    /// user picks it for that channel; see `Radio.displayed(_:)`.
    public var showImage = ""
    /// When this cut started, in stream time (live channels only): the song's zero point for
    /// the time-synced lyrics. Nil on Xtra, whose position comes from the player itself.
    public var startedAt: Date?

    public init(artist: String = "", song: String = "", image: String = "", showImage: String = "", startedAt: Date? = nil) {
        self.artist = artist; self.song = song; self.image = image; self.showImage = showImage; self.startedAt = startedAt
    }
}

// MARK: SiriusXM API (XtraClient)

public struct XtraChannel: Codable {
    public let id: String          // entity id (guid)
    public let number: String
    public let name: String
    public let genre: String
    public let imageURL: String
    public var isXtra = true       // false: a live (channel-linear) channel

    public init(id: String, number: String, name: String, genre: String, imageURL: String, isXtra: Bool = true) {
        self.id = id; self.number = number; self.name = name; self.genre = genre; self.imageURL = imageURL; self.isXtra = isXtra
    }
}

public struct XtraTrack: Sendable {
    public let id: String
    public let artist: String
    public let title: String
    public let url: String         // master playlist
    public let keyID: String
    public let imageURL: String
    public let startOffset: Double // seconds; non-zero only for the track already playing when tuned

    public init(id: String, artist: String, title: String, url: String, keyID: String, imageURL: String, startOffset: Double) {
        self.id = id; self.artist = artist; self.title = title; self.url = url; self.keyID = keyID
        self.imageURL = imageURL; self.startOffset = startOffset
    }
}

public enum XtraError: LocalizedError {
    case http(Int, String)
    case badResponse(String)
    public var errorDescription: String? {
        switch self {
        case .http(let code, let path): return "Xtra request failed (\(code)): \(path)"
        case .badResponse(let what): return "Unexpected Xtra response: \(what)"
        }
    }
}

// MARK: AppleScript

/// A script error with a message (raised to AppleScript as error -10000).
public struct ScriptFailure: Error {
    public let message: String
    public init(_ message: String) { self.message = message }
}

extension Channel {
    /// The search field's matching: number, name, category, "Music Xtra", artist and song.
    /// With `stars` the list is only those channels first (the "All Stars" filter).
    public static func filter(_ channels: [Channel], nowPlaying: [String: NowPlaying], search: String, stars: Set<String>? = nil) -> [Channel] {
        let channels = stars.map { stars in channels.filter { stars.contains($0.id) } } ?? channels
        guard !search.isEmpty else { return channels }
        return channels.filter { ch in
            let np = nowPlaying[ch.id]
            let xtraTerms = ch.xtraID != nil ? "Music Xtra" : ""
            return [ch.id, ch.name, ch.category, xtraTerms, np?.artist ?? "", np?.song ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }
}
