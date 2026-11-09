//
//  PlaybackWorker.swift
//  StarPlayrKit
//
//  Created by Todd Bruss on 10/31/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  Moved out of StarPlayrXMac's Radio.swift so iOS and the Mac share it.
//

import Foundation
import AVFoundation
import os

/// Player objects never leave this queue. The lock protects only copied values, never AVFoundation calls.
public final class PlaybackWorker: @unchecked Sendable {
    public static let shared = PlaybackWorker()
    public struct Snapshot {
        public var id: UUID?
        public var isXtra = false
        public var liveStatus: AVPlayer.TimeControlStatus = .paused
        public var xtraStatus: AVPlayer.TimeControlStatus = .paused
        public var liveTime = Double.nan
        public var xtraTime = Double.nan
        public var liveDate: Date?
        public var duration = Double.nan
        public var file: URL?
        public var track: XtraTrack?
        public var queueCount = 0

        public init() {}

        public func spectrum(ahead: Double) -> [Float]? {
            if isXtra {
                guard xtraStatus == .playing, xtraTime.isFinite, let file else { return nil }
                return SpectrumTimeline.shared.levels(track: file, at: xtraTime + ahead)
            }
            guard liveStatus == .playing, liveTime.isFinite else { return nil }
            return SpectrumTimeline.shared.levels(time: liveTime + ahead)
        }
    }
    private let queue = DispatchQueue(label: "com.starplayrx.playback", qos: .userInitiated)
    private let lock = NSLock()
    private var cached = Snapshot()
    public var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return cached }
    private lazy var live = AVPlayer()
    private lazy var xtra = AVQueuePlayer()
    private var id = UUID()
    private var isXtra = false
    private var loader: LiveLoader?
    private var tracks = [AVPlayerItem: (track: XtraTrack, file: URL)]()
    private var folder: URL?
    private var lastItem: AVPlayerItem?
    private var trackChanged: (@Sendable (UUID) -> Void)?
    private var timer: DispatchSourceTimer?

    private init() {
        queue.async {
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30, leeway: .milliseconds(3))
            timer.setEventHandler { self.sample() }
            self.timer = timer
            timer.resume()
        }
    }

    public func onTrackChange(_ callback: @escaping @Sendable (UUID) -> Void) {
        queue.async { self.trackChanged = callback }
    }

    public func begin(id: UUID, xtra: Bool, folder: URL) {
        queue.async {
            self.id = id
            self.isXtra = xtra
            self.live.pause()
            self.live.replaceCurrentItem(with: nil)
            self.xtra.pause()
            self.xtra.removeAllItems()
            self.loader?.isActive = false
            self.loader = nil
            self.tracks.removeAll()
            self.lastItem = nil
            SpectrumTimeline.shared.forgetTracks()
            SpectrumTimeline.shared.resetLive()
            if let old = self.folder { try? FileManager.default.removeItem(at: old) }
            self.folder = folder
            self.sample()
        }
    }

    public func loadLive(_ url: URL, client: XtraClient, id: UUID) {
        queue.async {
            guard self.id == id else { return }
            let (asset, loader) = LiveLoader.asset(for: url, client: client)
            self.loader = loader
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 3
            self.live.replaceCurrentItem(with: item)
            self.startLive(id: id, tries: 0)
        }
    }

    private func startLive(id: UUID, tries: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard self.id == id, let item = live.currentItem else { return }
        if (item.status != .readyToPlay || item.seekableTimeRanges.isEmpty), tries < 100 {
            queue.asyncAfter(deadline: .now() + 0.1) { self.startLive(id: id, tries: tries + 1) }
            return
        }
        if let range = item.seekableTimeRanges.last?.timeRangeValue {
            let edge = max(CMTimeSubtract(CMTimeRangeGetEnd(range), CMTime(seconds: 1, preferredTimescale: 1000)), range.start)
            if abs(CMTimeGetSeconds(CMTimeSubtract(edge, item.currentTime()))) > 1 {
                item.seek(to: edge, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    self.queue.async {
                        guard self.id == id else { return }
                        self.live.play()
                        self.sample()
                    }
                }
                return
            }
        }
        live.play()
        sample()
    }

    public func enqueue(_ track: XtraTrack, file: URL, first: Bool, id: UUID) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                guard self.id == id else { continuation.resume(); return }
                let item = AVPlayerItem(url: file)
                self.tracks[item] = (track, file)
                self.xtra.insert(item, after: nil)
                if first, track.startOffset > 0 {
                    self.xtra.seek(to: CMTime(seconds: track.startOffset, preferredTimescale: 1000)) { _ in
                        self.queue.async {
                            if self.id == id { self.xtra.play(); self.sample() }
                            continuation.resume()
                        }
                    }
                } else {
                    if first { self.xtra.play() }
                    self.sample()
                    continuation.resume()
                }
            }
        }
    }

    private func sample() {
        dispatchPrecondition(condition: .onQueue(queue))
        let queued = Set(xtra.items())
        for (item, entry) in tracks where !queued.contains(item) {
            tracks[item] = nil
            SpectrumTimeline.shared.forget(track: entry.file)
            try? FileManager.default.removeItem(at: entry.file)
        }
        let item = xtra.currentItem
        let liveItem = live.currentItem
        var state = Snapshot()
        state.id = id
        state.isXtra = isXtra
        state.liveStatus = live.timeControlStatus
        state.xtraStatus = xtra.timeControlStatus
        state.liveTime = liveItem?.currentTime().seconds ?? .nan
        state.xtraTime = item?.currentTime().seconds ?? .nan
        state.liveDate = liveItem?.currentDate()
        state.duration = item?.duration.seconds ?? .nan
        state.file = item.flatMap { tracks[$0]?.file }
        state.track = item.flatMap { tracks[$0]?.track }
        state.queueCount = queued.count
        lock.lock()
        cached = state
        lock.unlock()
        if item !== lastItem {
            lastItem = item
            trackChanged?(id)
        }
    }

    /// Moves the sound to another output with a fade down and back up. The output itself is the
    /// platform's business (DisplayAudio on the Mac): `isCurrent` skips the move, `warmUp` returns
    /// the cool-down to run at the end, `switchOutput` makes the switch at the quiet point.
    public func route(isCurrent: @escaping () -> Bool, warmUp: @escaping () -> () -> Void,
               switchOutput: @escaping () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                guard !isCurrent() else { continuation.resume(); return }
                let liveVolume = self.live.volume, xtraVolume = self.xtra.volume
                let cool = warmUp()
                self.fade(switchOutput: switchOutput, step: 1, liveVolume: liveVolume, xtraVolume: xtraVolume, cool: cool, continuation: continuation)
            }
        }
    }

    private func fade(switchOutput: @escaping () -> Void, step: Int, liveVolume: Float, xtraVolume: Float,
                      cool: @escaping () -> Void, continuation: CheckedContinuation<Void, Never>) {
        dispatchPrecondition(condition: .onQueue(queue))
        let gain = step <= 12 ? Float(1 + cos(Double(step) / 12 * .pi)) / 2
            : Float(1 - cos(Double(step - 12) / 16 * .pi)) / 2
        live.volume = liveVolume * gain
        xtra.volume = xtraVolume * gain
        if step == 28 {
            live.volume = liveVolume
            xtra.volume = xtraVolume
            cool()
            continuation.resume()
            return
        }
        queue.asyncAfter(deadline: .now() + 0.015) {
            if step == 12 {
                switchOutput()
                self.queue.asyncAfter(deadline: .now() + 0.1) {
                    self.fade(switchOutput: switchOutput, step: step + 1, liveVolume: liveVolume, xtraVolume: xtraVolume, cool: cool, continuation: continuation)
                }
            } else {
                self.fade(switchOutput: switchOutput, step: step + 1, liveVolume: liveVolume, xtraVolume: xtraVolume, cool: cool, continuation: continuation)
            }
        }
    }
}
