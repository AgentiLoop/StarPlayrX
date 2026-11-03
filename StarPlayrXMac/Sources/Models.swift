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

struct Channel: Identifiable, Hashable {
    let id: String          // channel number
    let name: String
    let category: String
    let imageURL: String
    var xtraID: String? = nil   // set for Xtra channels (streamed track by track)
}

struct NowPlaying: Equatable {
    var artist = ""
    var song = ""
    var image = ""
    /// The show's artwork (often a text title card), shown instead of the channel logo only when the
    /// user picks it for that channel; see `Radio.displayed(_:)`.
    var showImage = ""
}

// MARK: SiriusXM API (XtraClient)

struct XtraChannel {
    let id: String          // entity id (guid)
    let number: String
    let name: String
    let genre: String
    let imageURL: String
    var isXtra = true       // false: a live (channel-linear) channel
}

struct XtraTrack {
    let id: String
    let artist: String
    let title: String
    let url: String         // master playlist
    let keyID: String
    let imageURL: String
    let startOffset: Double // seconds; non-zero only for the track already playing when tuned
}

enum XtraError: LocalizedError {
    case http(Int, String)
    case badResponse(String)
    var errorDescription: String? {
        switch self {
        case .http(let code, let path): return "Xtra request failed (\(code)): \(path)"
        case .badResponse(let what): return "Unexpected Xtra response: \(what)"
        }
    }
}

// MARK: AppleScript

/// A script error with a message (raised to AppleScript as error -10000).
struct ScriptFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
