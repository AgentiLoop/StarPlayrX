//
//  PlayerState.swift
//  StarPlayrKit
//
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  What the iOS player and the Mac panel show, and what a tap on the art or the titles does:
//  one copy for both apps (the Mac's MenuController and the iOS views read and write this).
//

import Combine

@MainActor
public final class PlayerState: ObservableObject {
    public static let shared = PlayerState()

    /// The lyrics take the channel list's place.
    @Published public var lyrics = false
    @Published public var search = ""
    /// "All Stars": the list shows only the starred channels.
    @Published public var starsOnly = false
    /// The top-level chip over the list (Music, Sports, …; ChannelGroup); nil is "All Channels".
    @Published public var category: String? { didSet { if category != oldValue { subcategory = nil } } }
    /// The second-row chip inside `category` (NFL, Rock, …); nil is all of them.
    @Published public var subcategory: String?
    /// The current art full size, over the list or lyrics.
    @Published public var bigArt = false

    /// The channels the list shows right now (after the search, the stars filter and the chips).
    public var visibleChannels: [Channel] {
        let radio = Radio.shared
        return ChannelGroup.filter(Channel.filter(radio.channels, nowPlaying: radio.nowPlaying, search: search,
                                                  stars: starsOnly ? radio.presets : nil),
                                   group: category, sub: subcategory)
    }

    /// Whether the EQ bars animate (both apps): only while music plays, lyrics and big art included.
    public var barsRunning: Bool { Radio.shared.isPlaying }

    /// A tap on the now-playing art: full size first; while it's big, album art → channel logo →
    /// show art, and with nothing to switch to it closes again. False when there was nothing to do
    /// (no art at all), so the Mac can scroll the list to the channel instead.
    @discardableResult
    public func tapArt() -> Bool {
        let radio = Radio.shared
        if !bigArt, radio.shownArtURL != nil { bigArt = true; return true }
        if let id = radio.current?.id, radio.cycleArt(id) { return true }
        if bigArt { bigArt = false; return true }
        return false
    }

    /// A tap on the song/artist: the lyrics take the channel list's place, and back again.
    /// Over big art it first just closes the art, so the view underneath shows.
    public func tapTitles() {
        if bigArt { bigArt = false; return }
        lyrics.toggle()
    }

    /// A tap on the "All Stars" star: the list shows only the starred channels, or every channel
    /// again — and the list itself comes back in place of the lyrics or big art, so the change shows.
    public func tapStars() {
        starsOnly.toggle()
        bigArt = false
        lyrics = false
    }
}

extension Radio {
    /// The song the lyrics are for: what's coming out of the speakers, else what the row shows.
    public var lyricsSong: NowPlaying? {
        playingNow ?? current.flatMap { nowPlaying[$0.id] }
    }
}
