//
//  RadioSession.swift
//  StarPlayrKit
//
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  What the radio needs beyond the Mac: an audio session that keeps playing with the screen
//  locked, picking up again after a call or Siri, and next/previous channel from the lock
//  screen and Control Center — the same commands CarPlay's Now Playing screen sends.
//

import Foundation
import AVFoundation
import MediaPlayer

extension Radio {
    /// The channel `step` places along from the current one: through the starred channels when
    /// the current one is starred, else through every channel. Wraps around at either end.
    public func playAdjacent(_ step: Int) {
        let starred = channels.filter { presets.contains($0.id) }
        let list = current.map { presets.contains($0.id) } == true && starred.count > 1 ? starred : channels
        guard !list.isEmpty else { return }
        guard let current, let i = list.firstIndex(of: current) else { play(list[0]); return }
        play(list[((i + step) % list.count + list.count) % list.count])
    }
}

#if os(iOS) || os(tvOS)
extension Radio {
    /// Call once at launch on iPhone, iPad and Apple TV.
    public func startAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? session.setActive(true)
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                               object: session, queue: .main) { note in
            let info = note.userInfo
            guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options = (info?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            let resume = options?.contains(.shouldResume) ?? false
            Task { @MainActor in Radio.shared.interrupted(began: type == .began, shouldResume: resume) }
        }
        let commands = MPRemoteCommandCenter.shared()
        commands.nextTrackCommand.addTarget { _ in
            Task { @MainActor in Radio.shared.playAdjacent(1) }
            return .success
        }
        commands.previousTrackCommand.addTarget { _ in
            Task { @MainActor in Radio.shared.playAdjacent(-1) }
            return .success
        }
    }

    /// A call or Siri took the audio: stop cleanly (rather than leave the stall watchdog re-tuning
    /// into the call), and tune back in when it's over if the system says to.
    private func interrupted(began: Bool, shouldResume: Bool) {
        if began {
            Self.resumeAfterInterruption = isPlaying
            if isPlaying { stop() }
            return
        }
        guard Self.resumeAfterInterruption, shouldResume, let current else { return }
        Self.resumeAfterInterruption = false
        try? AVAudioSession.sharedInstance().setActive(true)
        play(current)
    }

    private static var resumeAfterInterruption = false
}
#endif
