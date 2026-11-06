//
//  StarPlayrXApp.swift
//  StarPlayrX (iOS / iPadOS)
//
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  One universal app for iPhone and iPad. The radio, lyrics and EQ code is StarPlayrKit, shared
//  with StarPlayrXMac; only the UI lives here.
//

import SwiftUI
import os
import StarPlayrKit

@main
struct StarPlayrXApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(Radio.shared)
                .task { await AppState.shared.launch() }
                // starplayrx://play/1001 tunes channel 1001, starplayrx://lyrics shows the lyrics
                // (`xcrun simctl openurl booted starplayrx://play/1001` drives the simulator).
                .onOpenURL { url in
                    let radio = Radio.shared
                    Logger(subsystem: "com.starplayrx.ios", category: "url").notice("open \(url.absoluteString, privacy: .public): \(radio.channels.count) channels")
                    switch url.host {
                    case "play":
                        if let ch = radio.channels.first(where: { $0.id == url.lastPathComponent }) { radio.play(ch) }
                    case "lyrics":
                        AppState.shared.lyrics = true
                    default: break
                    }
                }
        }
    }
}

/// What the Mac keeps in MenuController: which view is up, the search, the stars filter.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    /// The lyrics take the channel list's place.
    @Published var lyrics = false
    @Published var search = ""
    /// "All Stars": the list shows only the starred channels.
    @Published var starsOnly = false
    /// The top-level chip picked over the list (Music, Sports, …); nil is "All Channels".
    @Published var category: String? { didSet { if category != oldValue { genre = nil } } }
    /// The second-row chip inside `category` (NFL, Rock, …); nil is all of them.
    @Published var genre: String?
    /// The current art full size, over the list or lyrics.
    @Published var bigArt = false

    private var launched = false

    /// Runs after the first frame, so launch only draws. Keeps playing with the screen locked or
    /// another app in front (UIBackgroundModes audio), resumes after calls, next/previous channel on
    /// the lock screen (StarPlayrKit's RadioSession). With a saved account the player goes up at
    /// once from the channel list on disk, while the sign-in runs, as the Mac does at launch.
    func launch() async {
        guard !launched else { return }  // once, not per window (iPad has several)
        launched = true
        let radio = Radio.shared
        radio.startAudioSession()
        LyricSync.shared.start { AppState.shared.lyrics }
        guard !radio.isBusy, let saved = Keychain.load() else { return }
        radio.showCachedChannels()
        _ = await radio.login(user: saved.user, pass: saved.pass)
    }
}
