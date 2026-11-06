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
import os

public final class ShazamSync: @unchecked Sendable {
    public static let shared = ShazamSync()

    /// A match: the recording Shazam heard, and the real broadcast time at which the record was
    /// `offset` seconds in.
    public struct Match { public let artist: String; public let title: String; public let offset: TimeInterval; public let real: Date; public let found: Date }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "StarPlayrX.shazam", qos: .utility)
    private var latest: Match?
    private var lastError: String?
    /// Only listen while the lyrics want it (the pane's tick renews this), so a closed pane
    /// costs nothing and asks Shazam nothing.
    private var wantedUntil = Date.distantPast
    /// Set while the newest match isn't the song playing now (a new song, a skip): ask on every
    /// segment until one is, instead of waiting out `refresh` with the lyrics out of step.
    private var eager = false
    /// When the request in flight went out. A session that never answers used to leave `busy` set
    /// for good, and Shazam never matched again until the app was restarted.
    private var askedAt: Date?
    private var asks = 0
    /// Shazam matches stay good while the song plays, so once one is in, ask again only now and
    /// then, to follow a new song or a skip, not every segment.
    public static let refresh: TimeInterval = 30
    public static let timeout: TimeInterval = 20
    /// Every failure goes to the log, on the Mac and on iOS:
    /// `log stream --predicate 'subsystem BEGINSWITH "com.starplayrx" AND category == "shazam"'`.
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.starplayrx", category: "shazam")

    /// The newest match, and why there isn't one if matching keeps failing.
    public var current: (match: Match?, error: String?) {
        lock.lock(); defer { lock.unlock() }
        return (latest, lastError)
    }

    /// Called from the lyrics pane's tick: keep matching for the next half minute. `eager` when the
    /// newest match isn't for the song playing now.
    public func want(eager: Bool = false) {
        lock.lock(); wantedUntil = Date().addingTimeInterval(30); self.eager = eager; lock.unlock()
    }

    /// Takes the one request slot when it is free (or its request has gone unanswered too long).
    private func claim(_ now: Date) -> Int? {
        if let askedAt {
            guard now.timeIntervalSince(askedAt) >= Self.timeout else { return nil }
            Self.log.error("Shazam request \(self.asks) got no answer in \(Int(Self.timeout))s; asking again")
        }
        askedAt = now
        asks += 1
        return asks
    }

    /// A live segment has just been decoded to `file`, whose first sample went out on air at `real`.
    /// The file is deleted after this returns, so its audio is read here, on the caller's thread.
    public func segment(_ file: URL, real: Date) {
        lock.lock()
        let now = Date()
        let due = now < wantedUntil
            && (eager || (latest.map { now.timeIntervalSince($0.found) >= Self.refresh } ?? true))
        let ask = due ? claim(now) : nil
        lock.unlock()
        guard let ask else { return }
        guard let signature = Self.signature(file) else {
            Self.log.error("Shazam: no signature from live segment \(file.lastPathComponent, privacy: .public)")
            finish(ask) { $0.lastError = "no signature" }
            return
        }
        match(signature, ask) { [self] media, error in
            finish(ask) {
                if let media, let title = media.title {
                    $0.latest = Match(artist: media.artist ?? "", title: title, offset: media.matchOffset, real: real, found: Date())
                    $0.lastError = nil
                } else { $0.lastError = error }
            }
        }
    }

    /// An Xtra track: matches 9.75 s of the downloaded file from `seconds` on — one segment's worth,
    /// as on the live channels. `done` gets the
    /// match, whose `offset` is how far into the record the file is at `seconds` (nil on no match,
    /// or when another request is in flight).
    public func track(_ file: URL, at seconds: Double, done: @escaping @Sendable (Match?) -> Void) {
        lock.lock()
        let ask = claim(Date())
        lock.unlock()
        guard let ask else { done(nil); return }
        queue.async { [self] in
            guard let signature = Self.signature(file, from: seconds, length: 9.75) else {
                Self.log.error("Shazam: no signature from Xtra \(file.lastPathComponent, privacy: .public) at \(seconds)s")
                finish(ask) { _ in }; done(nil); return
            }
            match(signature, ask) { [self] media, _ in
                finish(ask) { _ in }
                guard let media, let title = media.title else { done(nil); return }
                done(Match(artist: media.artist ?? "", title: title, offset: media.matchOffset, real: Date(), found: Date()))
            }
        }
    }

    private func match(_ signature: SHSignature, _ ask: Int, done: @escaping (SHMatchedMediaItem?, String?) -> Void) {
        queue.async { [self] in
            let session = SHSession()
            let delegate = Delegate(done)
            session.delegate = delegate
            lock.lock(); if asks == ask { pending = (session, delegate) }; lock.unlock()   // the session holds its delegate weakly
            session.match(signature)
        }
    }

    /// The session in flight and its delegate, kept alive until the answer comes back.
    private var pending: (SHSession, Delegate)?

    /// Applies a request's answer and frees the slot, unless the request timed out and a newer
    /// one has taken its place.
    private func finish(_ ask: Int, _ apply: (ShazamSync) -> Void) {
        lock.lock()
        if ask == asks {
            apply(self)
            askedAt = nil
            pending = nil
        }
        lock.unlock()
    }

    /// The whole segment as one signature (or `length` seconds of it from `from`); Shazam wants at
    /// least a few seconds, and ~9.75 s is plenty.
    private static func signature(_ file: URL, from: Double = 0, length: Double? = nil) -> SHSignature? {
        guard let audio = try? AVAudioFile(forReading: file) else { return nil }
        let rate = audio.processingFormat.sampleRate
        let start = AVAudioFramePosition(max(0, from) * rate)
        guard rate > 0, start < audio.length else { return nil }
        audio.framePosition = start
        let frames = min(audio.length - start, length.map { AVAudioFramePosition($0 * rate) } ?? audio.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(frames)),
              (try? audio.read(into: buffer, frameCount: AVAudioFrameCount(frames))) != nil, buffer.frameLength > 0 else { return nil }
        let generator = SHSignatureGenerator()
        guard (try? generator.append(buffer, at: nil)) != nil else { return nil }
        return generator.signature()
    }

    private final class Delegate: NSObject, SHSessionDelegate {
        let done: (SHMatchedMediaItem?, String?) -> Void
        init(_ done: @escaping (SHMatchedMediaItem?, String?) -> Void) { self.done = done }
        func session(_ session: SHSession, didFind match: SHMatch) {
            let item = match.mediaItems.first
            ShazamSync.log.notice("Shazam match: \(item?.artist ?? "?", privacy: .public) – \(item?.title ?? "?", privacy: .public) at \(item?.matchOffset ?? 0)s")
            done(item, nil)
        }
        func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
            if let error {
                // An app ID without ShazamKit (App Services), no network, or a throttled account all land here.
                let ns = error as NSError
                ShazamSync.log.error("Shazam error \(ns.domain, privacy: .public) \(ns.code): \(ns.localizedDescription, privacy: .public)")
            } else {
                ShazamSync.log.info("Shazam: no match")
            }
            done(nil, error.map { "\($0.localizedDescription)" } ?? "no match")
        }
    }
}
