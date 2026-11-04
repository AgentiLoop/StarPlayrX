//
//  ShazamSync.swift
//  StarPlayrXMac
//
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  Where a live song really is, from ShazamKit. Each decoded segment (~9.75 s) is turned into a
//  Shazam signature and matched against Shazam's catalogue. A match names the recording and says
//  how far into it the segment's first sample is (`matchOffset`). The segment's first sample is
//  also stamped with its real broadcast time, so "this moment on air is that many seconds into the
//  record" is known outright: no guessing from the audio, no trust in the cut's start stamp, and
//  no trouble with DJ talk-ups, cross-fades, dense mixes or rap. `LyricSync` turns it into the
//  shift and keeps its own aligner as the fallback for songs Shazam doesn't know.
//
//  ShazamKit has to be turned on for the app's ID (App Services) in the Apple Developer portal;
//  until it is, every match fails and the aligner carries on alone.
//

import Foundation
import AVFoundation
import ShazamKit

final class ShazamSync: @unchecked Sendable {
    static let shared = ShazamSync()

    /// A match: the recording Shazam heard, and the real broadcast time at which the record was
    /// `offset` seconds in.
    struct Match { let artist: String; let title: String; let offset: TimeInterval; let real: Date; let found: Date }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "StarPlayrX.shazam", qos: .utility)
    private var latest: Match?
    private var lastError: String?
    /// Only listen while the lyrics want it (the pane's tick renews this), so a closed pane
    /// costs nothing and asks Shazam nothing.
    private var wantedUntil = Date.distantPast
    private var busy = false
    /// Shazam matches stay good while the song plays, so once one is in, ask again only now and
    /// then, to follow a new song or a skip, not every segment.
    static let refresh: TimeInterval = 30

    /// The newest match, and why there isn't one if matching keeps failing.
    var current: (match: Match?, error: String?) {
        lock.lock(); defer { lock.unlock() }
        return (latest, lastError)
    }

    /// Called from the lyrics pane's tick: keep matching for the next half minute.
    func want() {
        lock.lock(); wantedUntil = Date().addingTimeInterval(30); lock.unlock()
    }

    /// A live segment has just been decoded to `file`, whose first sample went out on air at `real`.
    /// The file is deleted after this returns, so its audio is read here, on the caller's thread.
    func segment(_ file: URL, real: Date) {
        lock.lock()
        let now = Date()
        let due = now < wantedUntil && !busy
            && (latest.map { now.timeIntervalSince($0.found) >= Self.refresh } ?? true)
        if due { busy = true }
        lock.unlock()
        guard due else { return }
        guard let signature = Self.signature(file) else { finish(nil, "no signature"); return }
        queue.async { [self] in
            let session = SHSession()
            let delegate = Delegate { [self] media, error in
                guard let media, let title = media.title else { finish(nil, error); return }
                finish(Match(artist: media.artist ?? "", title: title, offset: media.matchOffset,
                             real: real, found: Date()), nil)
            }
            session.delegate = delegate
            lock.lock(); pending = (session, delegate); lock.unlock()   // the session holds its delegate weakly
            session.match(signature)
        }
    }

    /// The session in flight and its delegate, kept alive until the answer comes back.
    private var pending: (SHSession, Delegate)?

    private func finish(_ match: Match?, _ error: String?) {
        lock.lock()
        if let match { latest = match; lastError = nil } else { lastError = error }
        busy = false
        pending = nil
        lock.unlock()
    }

    /// The whole segment as one signature; Shazam wants at least a few seconds, and ~9.75 s is plenty.
    private static func signature(_ file: URL) -> SHSignature? {
        guard let audio = try? AVAudioFile(forReading: file),
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)),
              (try? audio.read(into: buffer)) != nil, buffer.frameLength > 0 else { return nil }
        let generator = SHSignatureGenerator()
        guard (try? generator.append(buffer, at: nil)) != nil else { return nil }
        return generator.signature()
    }

    private final class Delegate: NSObject, SHSessionDelegate {
        let done: (SHMatchedMediaItem?, String?) -> Void
        init(_ done: @escaping (SHMatchedMediaItem?, String?) -> Void) { self.done = done }
        func session(_ session: SHSession, didFind match: SHMatch) { done(match.mediaItems.first, nil) }
        func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
            done(nil, error.map { "\($0.localizedDescription)" } ?? "no match")
        }
    }
}
