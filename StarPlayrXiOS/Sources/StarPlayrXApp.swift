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
import AVFoundation
import StarPlayrKit

@main
struct StarPlayrXApp: App {
    init() {
        // Radio keeps playing with the screen locked or another app in front (UIBackgroundModes audio).
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? session.setActive(true)
        LyricSync.shared.start { AppState.shared.lyrics }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(Radio.shared)
                .task { await AppState.shared.signInWithSaved() }
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

    /// Signs in with the account saved in the Keychain, as the Mac does at launch.
    func signInWithSaved() async {
        let radio = Radio.shared
        guard !radio.isLoggedIn, !radio.isBusy, let saved = Keychain.load() else { return }
        _ = await radio.login(user: saved.user, pass: saved.pass)
    }
}
