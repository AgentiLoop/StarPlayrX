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
                    Log(subsystem: "com.starplayrx.ios", category: "url").notice("open \(url.absoluteString): \(radio.channels.count) channels")
                    switch url.host {
                    case "play":
                        if let ch = radio.channels.first(where: { $0.id == url.lastPathComponent }) { radio.play(ch) }
                    case "lyrics":
                        PlayerState.shared.lyrics = true
                    default: break
                    }
                }
        }
    }
}

/// The launch steps. What the views show (lyrics, search, stars, chips, big art) is StarPlayrKit's
/// PlayerState, shared with the Mac.
@MainActor
final class AppState {
    static let shared = AppState()

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
        LyricSync.shared.start { PlayerState.shared.lyrics }
        guard !radio.isBusy, let saved = Keychain.load() else { return }
        radio.showCachedChannels()
        _ = await radio.login(user: saved.user, pass: saved.pass)
    }
}
