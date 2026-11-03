//
//  Radio.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 10/31/26.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import Foundation
import AVFoundation
import MediaPlayer
import Combine
import os

@MainActor
final class Radio: ObservableObject {
    static let shared = Radio()

    @Published var status = "Not signed in"
    @Published var isBusy = false
    @Published var isLoggedIn = false
    @Published var isPlaying = false
    @Published var channels = [Channel]()
    @Published var current: Channel?
    @Published var nowPlaying = [String: NowPlaying]()
    /// Channels where the user clicked the artwork to see the show's art instead of the channel logo.
    /// Logo is the default; the choice is per channel and remembered.
    @Published private(set) var showArtChannels = Set(UserDefaults.standard.stringArray(forKey: "showArtChannels") ?? [])

    /// Now playing as shown: song art if any, else the show's art on channels where the user chose it,
    /// else no image (the channel logo is drawn).
    func displayed(_ id: String) -> NowPlaying? {
        guard var np = nowPlaying[id] else { return nil }
        if np.image.isEmpty, showArtChannels.contains(id) { np.image = np.showImage }
        return np
    }

    /// Clicking the artwork switches between the channel logo and the show's art, for that channel only.
    /// Returns false when there is nothing to switch to (song art, or no show art).
    @discardableResult
    func toggleShowArt(_ id: String) -> Bool {
        guard let np = nowPlaying[id], np.image.isEmpty, !np.showImage.isEmpty else { return false }
        if showArtChannels.contains(id) { showArtChannels.remove(id) } else { showArtChannels.insert(id) }
        UserDefaults.standard.set(Array(showArtChannels).sorted(), forKey: "showArtChannels")
        return true
    }
    /// Starred channels ("presets" on iOS; same key and starting set as the iOS app). Kept on this
    /// Mac only, not on the SiriusXM account.
    @Published private(set) var presets = Set(UserDefaults.standard.stringArray(forKey: "SPXPresets") ?? ["2", "3", "4"])

    /// The star: adds the channel to the presets, or takes it out. Remembered.
    func togglePreset(_ id: String) {
        if presets.contains(id) { presets.remove(id) } else { presets.insert(id) }
        UserDefaults.standard.set(Array(presets).sorted { Int($0) ?? 0 < Int($1) ?? 0 }, forKey: "SPXPresets")
    }
    /// Canadian account: the API is the same, the request locale is en-CA (as can.siriusxm.com sends).
    @Published var localeIsCA = UserDefaults.standard.bool(forKey: "localeIsCA")
    /// True once sign-in has finished loading every channel, Xtra included.
    @Published var channelsLoaded = false

    private let player = AVPlayer()
    private var pdtTimer: Timer?

    // Xtra channels: tracks are downloaded, decrypted and queued one after another.
    private let xtra = XtraClient()
    private let xtraPlayer = AVQueuePlayer()
    private var xtraTask: Task<Void, Never>?
    private var xtraTracks = [AVPlayerItem: XtraTrack]()
    private var xtraNowPlaying = [String: NowPlaying]()
    private var liveIDs = [String: String]()   // live channel number -> entity id, for the lookAround feed
    private var xtraObserver: AnyCancellable?
    private var xtraPeekedAt = [String: Date]()
    private var xtraPeekedTrack = [String: XtraTrack]()  // what the channel list shows, played first on tune
    private var xtraPeeking = false
    private var liveLoader: LiveLoader?   // keeps the live stream's resource loader alive
    private let xtraFolder = FileManager.default.temporaryDirectory.appendingPathComponent("StarPlayrXtra")

    private init() {
        setupRemoteCommands()
        xtraObserver = xtraPlayer.publisher(for: \.currentItem)
            .receive(on: DispatchQueue.main)
            .sink { _ in Task { @MainActor in Radio.shared.xtraItemChanged() } }
    }

    // MARK: Login

    /// Signs in to the SiriusXM API; every channel (live and Xtra) comes from XtraClient.channels().
    func login(user: String, pass: String) async -> Bool {
        isBusy = true
        channelsLoaded = false
        defer { isBusy = false }
        status = "Signing in…"
        let all: [XtraChannel]
        do {
            await xtra.setLocale(localeIsCA ? "en-CA" : "en-US")
            try await xtra.signIn(user: user, pass: pass)
            status = "Loading channels…"
            all = try await xtra.channels()
        } catch {
            status = error.localizedDescription
            return false
        }
        guard !all.isEmpty else { status = "Error reading channels."; return false }
        Keychain.save(user: user, pass: pass)
        liveIDs = Dictionary(all.filter { !$0.isXtra }.map { ($0.number, $0.id) }) { first, _ in first }
        channels = all.map {
            Channel(id: $0.number, name: $0.name, category: $0.genre, imageURL: $0.imageURL, xtraID: $0.isXtra ? $0.id : nil)
        }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        isLoggedIn = true
        channelsLoaded = true
        status = "Signed in"
        if let last = UserDefaults.standard.string(forKey: "lastChannel") {
            current = channels.first { $0.id == last }
            if let current, !isPlaying { play(current) }
        }
        await updatePDT()
        startPDTTimer()
        return true
    }

    func signOut() {
        stop()
        pdtTimer?.invalidate()
        Keychain.delete()
        Task { await xtra.signOut() }
        isLoggedIn = false
        channelsLoaded = false
        channels = []
        lookAround = [:]
        current = nil
        status = "Not signed in"
    }

    /// Canada or US. Takes effect at the next sign-in.
    func setRegion(ca: Bool) {
        localeIsCA = ca
        UserDefaults.standard.set(ca, forKey: "localeIsCA")
    }

    // MARK: Playback

    func play(_ channel: Channel) {
        haltXtra()
        current = channel
        UserDefaults.standard.set(channel.id, forKey: "lastChannel")
        // A tune the user asked for starts the stall count over; a re-tune by the watchdog keeps it.
        if retuning { retuning = false } else { recoveryAttempts = 0 }
        startWatchdog()
        if let xtraID = channel.xtraID {
            player.pause()
            player.replaceCurrentItem(with: nil)
            playXtra(channel, id: xtraID)
            return
        }
        Task {
            liveLoader?.isActive = false
            liveLoader = nil
            // Before the new item exists, so the EQ is dated from the first playlist that item loads.
            SpectrumTimeline.shared.resetLive()
            guard let liveID = liveIDs[channel.id] else { status = "Channel \(channel.id) is not available."; stop(); return }
            let live: URL
            do { live = try await xtra.liveStream(channelID: liveID) } catch { status = error.localizedDescription; stop(); return }
            // Playlists and the AES key go through LiveLoader; the signed segment URLs load directly.
            let (asset, loader) = LiveLoader.asset(for: live, client: xtra)
            liveLoader = loader
            let item = AVPlayerItem(asset: asset)
            // Start as soon as a little audio is buffered instead of waiting to fill a large buffer.
            item.preferredForwardBufferDuration = 3
            // Stay paused until the start position is settled so the old position never plays
            // (that was the half-second stutter before the jump).
            player.pause()
            player.replaceCurrentItem(with: item)
            isPlaying = true
            var tries = 0
            while (item.status != .readyToPlay || item.seekableTimeRanges.isEmpty), tries < 100 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                tries += 1
            }
            guard player.currentItem === item else { return }
            // Fallback: only jump if the start tag was ignored and we're more than 1 s off live.
            if let range = item.seekableTimeRanges.last?.timeRangeValue {
                let edge = max(CMTimeSubtract(CMTimeRangeGetEnd(range), CMTime(seconds: 1, preferredTimescale: 1000)), range.start)
                if abs(CMTimeGetSeconds(CMTimeSubtract(edge, item.currentTime()))) > 1 {
                    // Exact seek so we land within 1 s of live, not on an earlier segment boundary.
                    await item.seek(to: edge, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
            guard player.currentItem === item else { return }
            player.play()
            await updatePDT()
        }
    }

    func togglePlayPause() {
        if isPlaying { stop() } else if let current { play(current) }
    }

    func stop() {
        stopWatchdog()
        player.pause()
        player.replaceCurrentItem(with: nil)
        haltXtra()
        isPlaying = false
        updateNowPlayingInfo()
    }

    // MARK: Stall recovery

    /// The stream can die on its own — the Mac sleeps, the network drops, a segment or the playlist
    /// fails — and AVPlayer just stops. Nothing cleared `isPlaying`, so the button stayed on Pause
    /// over silence and nothing ever brought the audio back. This watchdog notices the silence,
    /// re-tunes the channel, and after a few failed tries gives up and shows Play again.
    private var watchdog: Timer?
    private var silentSince: Date?
    private var recoveryAttempts = 0
    private var retuning = false
    /// Longer than the tune path's own wait for the first segments (10 s), so a slow start
    /// is never mistaken for a dead stream.
    private static let stallSeconds: TimeInterval = 12
    private static let maxRecoveryAttempts = 3

    private func startWatchdog() {
        silentSince = nil
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in Radio.shared.checkPlayback() }
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
        silentSince = nil
    }

    /// True while the current channel is making no sound at all. Buffering counts: it is only acted
    /// on after `stallSeconds` of it. An Xtra channel between downloaded tracks does not count.
    private var isSilent: Bool {
        guard let current else { return false }
        guard current.xtraID == nil else {
            return xtraPlayer.timeControlStatus != .playing && xtraPlayer.items().isEmpty
        }
        return player.timeControlStatus != .playing
    }

    private func checkPlayback() {
        // A live tune sets isPlaying only after the stream URL comes back; stop() is what ends the watchdog.
        guard isPlaying, let channel = current else { silentSince = nil; return }
        guard isSilent else { silentSince = nil; recoveryAttempts = 0; return }
        let since = silentSince ?? Date()
        silentSince = since
        guard Date().timeIntervalSince(since) >= Self.stallSeconds else { return }
        silentSince = nil
        guard recoveryAttempts < Self.maxRecoveryAttempts else {
            Self.playLog.error("playback gave up ch=\(channel.id, privacy: .public) after \(self.recoveryAttempts, privacy: .public) tries")
            stop()
            status = "Playback stopped. Press play to try again."
            return
        }
        recoveryAttempts += 1
        Self.playLog.notice("playback stalled ch=\(channel.id, privacy: .public) re-tuning, try \(self.recoveryAttempts, privacy: .public)")
        retuning = true
        play(channel)
    }
    private static let playLog = Logger(subsystem: "com.starplayrx.mac", category: "playback")

    // MARK: Xtra playback

    private func playXtra(_ channel: Channel, id: String) {
        isPlaying = true
        // Tuning again returns a different track than the peek, so start with the peeked track
        // the channel list is showing (from its beginning), then continue with the tuned queue.
        let peeked = xtraPeekedTrack.removeValue(forKey: channel.id).map {
            XtraTrack(id: $0.id, artist: $0.artist, title: $0.title, url: $0.url, keyID: $0.keyID,
                      imageURL: $0.imageURL, startOffset: 0)
        }
        print("XTRA play \(channel.id) shown=\(nowPlaying[channel.id]?.song ?? "nil") peeked=\(peeked?.title ?? "nil")")
        if peeked == nil {
            xtraNowPlaying[channel.id] = nil
            nowPlaying[channel.id] = nil
        }
        updateNowPlayingInfo()
        xtraTask = Task {
            var pending = [XtraTrack]()
            var token: String?
            var seen = Set<String>()
            var first = true
            if let peeked {
                seen.insert(peeked.id)
                do {
                    let file = try await xtra.download(peeked, into: xtraFolder)
                    if !Task.isCancelled {
                        SpectrumTimeline.shared.analyze(track: file)
                        let item = AVPlayerItem(url: file)
                        xtraTracks[item] = peeked
                        xtraPlayer.insert(item, after: nil)
                        first = false
                        xtraPlayer.play()
                        xtraItemChanged()
                    }
                } catch {
                    print("XTRA peeked download failed \(channel.id) \(peeked.title): \(error.localizedDescription) url=\(peeked.url)")
                }
            }
            do {
                while !Task.isCancelled {
                    // Keep one track playing and one ready behind it.
                    if xtraPlayer.items().count > 1 {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        continue
                    }
                    if pending.isEmpty {
                        let batch = try await xtra.tune(channelID: id, sequenceToken: token)
                        token = batch.token
                        pending = batch.tracks.filter { seen.insert($0.id).inserted }
                        if pending.isEmpty { try await Task.sleep(nanoseconds: 5_000_000_000); continue }
                    }
                    let track = pending.removeFirst()
                    let file = try await xtra.download(track, into: xtraFolder)
                    guard !Task.isCancelled else { break }
                    SpectrumTimeline.shared.analyze(track: file, from: first ? track.startOffset : 0)
                    let item = AVPlayerItem(url: file)
                    xtraTracks[item] = track
                    xtraPlayer.insert(item, after: nil)
                    if first {
                        first = false
                        if track.startOffset > 0 {
                            await xtraPlayer.seek(to: CMTime(seconds: track.startOffset, preferredTimescale: 1000))
                        }
                        xtraPlayer.play()
                        xtraItemChanged()
                    }
                }
            } catch is CancellationError {
            } catch {
                print("Xtra playback error: \(error.localizedDescription)")
                if first, current?.id == channel.id { stop() }
            }
        }
    }

    private func haltXtra() {
        // The list keeps showing the song that was playing, so tuning back in should play that song.
        if let item = xtraPlayer.currentItem, let track = xtraTracks[item], let current, current.xtraID != nil {
            xtraPeekedTrack[current.id] = track
        }
        xtraTask?.cancel()
        xtraTask = nil
        xtraPlayer.pause()
        xtraPlayer.removeAllItems()
        xtraTracks = [:]
        SpectrumTimeline.shared.forgetTracks()
        try? FileManager.default.removeItem(at: xtraFolder)
    }

    /// Shows the queued track that just started and deletes files of tracks that have finished.
    fileprivate func xtraItemChanged() {
        let queued = Set(xtraPlayer.items())
        for (item, track) in xtraTracks where !queued.contains(item) {
            xtraTracks[item] = nil
            let file = xtraFolder.appendingPathComponent("\(track.id).aac")
            SpectrumTimeline.shared.forget(track: file)
            try? FileManager.default.removeItem(at: file)
        }
        guard let item = xtraPlayer.currentItem, let track = xtraTracks[item], let current, current.xtraID != nil else { return }
        let np = NowPlaying(artist: track.artist, song: track.title, image: track.imageURL)
        // Called from both the queue observer and playXtra for the same item: log the track once.
        if xtraNowPlaying[current.id] != np { print("XTRA playing \(current.id) \(track.artist) – \(track.title)") }
        xtraNowPlaying[current.id] = np
        nowPlaying[current.id] = np
        updateNowPlayingInfo()
    }

    // MARK: Now playing (PDT)

    private func startPDTTimer() {
        pdtTimer?.invalidate()
        pdtTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in await Radio.shared.updatePDT() }
        }
    }

    func updatePDT() async {
        // One source for every live row, tuned or not: the newer API (lookAround).
        // The player's date runs ahead of the stream's real PDT (segments are tagged 10 s but hold
        // ~9.75 s, so the gap grows to ~8 s). The song list was matched to the player's date, so it
        // ran that far ahead of the music; hold it back by the measured gap.
        if current?.xtraID == nil, player.timeControlStatus == .playing, let at = player.currentItem?.currentDate(),
           let real = SpectrumTimeline.shared.realDate(at: at) {
            streamLag = max(0, at.timeIntervalSince(real))
        }
        // How far behind the live feed the audio really is: the player's own date for the frames
        // coming out now, not the wall clock. Buffering, a pause or a rewind puts the music further
        // back without changing `streamLag`, and the song titles would run that far ahead of it.
        let behind = heardDate.map { max(0, Date().timeIntervalSince($0)) } ?? streamLag
        if let live = try? await xtra.liveNowPlaying(behind: behind) {
            for (number, id) in liveIDs {
                guard let la = live[id] else { continue }
                lookAround[number] = Self.keepingArt(la, of: lookAround[number])
            }
        }
        nowPlaying = lookAround.merging(xtraNowPlaying) { live, _ in live }
        updateNowPlayingInfo()
        Task { await refreshXtraNowPlaying() }
    }
    private var streamLag: TimeInterval = 8   // measured above; ~8 s until the first measurement
    private var lookAround = [String: NowPlaying]()   // last lookAround cut per live channel number

    /// Xtra channels have no PDT feed, so ask each idle one what it would play if tuned now.
    /// Channels never peeked are all filled at once; after that the stalest are refreshed
    /// a batch at a time on every PDT tick. Each result is shown as soon as it arrives.
    private func refreshXtraNowPlaying() async {
        guard isLoggedIn, !xtraPeeking else { return }
        xtraPeeking = true
        defer { xtraPeeking = false }
        let stale = Date().addingTimeInterval(-180)
        let idle = channels.filter { $0.xtraID != nil && !isPlayingXtra($0.id) }
        let unpeeked = idle.filter { xtraPeekedAt[$0.id] == nil }
        let batch = !unpeeked.isEmpty ? unpeeked : Array(idle
            .filter { (xtraPeekedAt[$0.id] ?? .distantPast) < stale }
            .sorted { (xtraPeekedAt[$0.id] ?? .distantPast) < (xtraPeekedAt[$1.id] ?? .distantPast) }
            .prefix(30))
        guard !batch.isEmpty else { return }
        let client = xtra
        await withTaskGroup(of: (String, XtraTrack?).self) { group in
            for (i, ch) in batch.enumerated() {
                guard let xtraID = ch.xtraID else { continue }
                if i >= 12, let r = await group.next() { applyXtraPeek(r.0, r.1) }
                group.addTask { (ch.id, try? await client.peek(channelID: xtraID)) }
            }
            for await r in group { applyXtraPeek(r.0, r.1) }
        }
    }

    /// Peek results arrive many per second; publishing each one redraws the whole channel
    /// list and stalls scrolling, so they're batched and published at most every 2 seconds.
    private func applyXtraPeek(_ id: String, _ track: XtraTrack?) {
        guard isLoggedIn else { return }
        xtraPeekedAt[id] = Date()
        guard let track, !isPlayingXtra(id) else { return }
        // The played track, xtraNowPlaying and the list text are committed together on flush,
        // so tapping a channel always plays the song its row is showing.
        pendingPeeks[id] = track
        guard !peekFlushScheduled else { return }
        peekFlushScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            peekFlushScheduled = false
            let tracks = pendingPeeks.filter { !isPlayingXtra($0.key) }
            pendingPeeks.removeAll()
            guard isLoggedIn, !tracks.isEmpty else { return }
            let batch = Dictionary(uniqueKeysWithValues: tracks.map { id, track in
                (id, Self.keepingArt(NowPlaying(artist: track.artist, song: track.title, image: track.imageURL), of: nowPlaying[id]))
            })
            xtraPeekedTrack.merge(tracks) { _, new in new }
            xtraNowPlaying.merge(batch) { _, new in new }
            nowPlaying.merge(batch) { _, new in new }
        }
    }
    /// The PDT feed only has album art for songs the server has just seen on a now-playing-live
    /// fetch (it forgets them on the next one), so a later poll of the same song often comes back
    /// without art. Keep the album art until the song changes, instead of flipping back to the logo.
    nonisolated static func keepingArt(_ new: NowPlaying, of old: NowPlaying?) -> NowPlaying {
        guard new.image.isEmpty, let old, !old.image.isEmpty, old.artist == new.artist, old.song == new.song else { return new }
        var kept = new
        kept.image = old.image
        return kept
    }
    private var pendingPeeks = [String: XtraTrack]()
    private var peekFlushScheduled = false

    /// What is actually coming out of the speakers: the Xtra track in the player, or the live channel's PDT.
    var playingNow: NowPlaying? {
        guard isPlaying, let current else { return nil }
        guard current.xtraID != nil else { return nowPlaying[current.id] }
        guard let item = xtraPlayer.currentItem, let track = xtraTracks[item] else { return nil }
        return NowPlaying(artist: track.artist, song: track.title, image: track.imageURL)
    }

    /// Seconds into the song that's playing, for the time-synced lyrics. Xtra tracks are whole
    /// files in the player, so the player knows. A live channel's stream has no song boundaries:
    /// the cut's `validFrom` is the song's start in stream time, and the music runs `streamLag`
    /// behind real time, so now minus that lag minus the start is how far into the song it is.
    var trackPosition: TimeInterval? {
        guard isPlaying else { return nil }
        guard current?.xtraID != nil else {
            guard let started = current.flatMap({ nowPlaying[$0.id] })?.startedAt,
                  let heard = heardDate else { return nil }
            let at = heard.timeIntervalSince(started) + Self.liveLyricsLead
            // A talk segment or a stale cut can run for hours; past that these aren't its lyrics.
            return (0...900).contains(at) ? at : nil
        }
        guard xtraPlayer.timeControlStatus != .paused, let item = xtraPlayer.currentItem else { return nil }
        let at = item.currentTime().seconds
        return at.isFinite ? at : nil
    }

    /// Broadcast time of the audio coming out of the speakers right now on a live channel: the
    /// player's own date for those frames, put back on the stream's real PROGRAM-DATE-TIME. This is
    /// what both the song list and the lyrics are matched against, so neither runs ahead of the
    /// music when the player buffers, is paused, or is rewound.
    private var heardDate: Date? {
        guard current?.xtraID == nil, let at = player.currentItem?.currentDate() else { return nil }
        return SpectrumTimeline.shared.realDate(at: at) ?? at.addingTimeInterval(-streamLag)
    }

    /// Seconds added to where the cut's timestamp says we are. A live cut is stamped a little
    /// before the recording's own zero (the station fades in over the end of the last song, and the
    /// stamp is published early), so without this the lines run ahead of the singing. How far is
    /// per song — a radio edit is cut differently from the record LRCLIB has — so this is the
    /// middle of what the live channels show; `defaults write com.starplayrx.mac lyricsLiveLead
    /// -float -1` (or 0, or -3) moves it without a rebuild.
    static var liveLyricsLead: TimeInterval {
        UserDefaults.standard.object(forKey: "lyricsLiveLead") as? Double ?? 0.5
    }

    /// Length of the Xtra track in the player, which sharpens LRCLIB's matching. Nil on live channels.
    var trackDuration: TimeInterval? {
        guard current?.xtraID != nil, let item = xtraPlayer.currentItem else { return nil }
        let length = item.duration.seconds
        return length.isFinite && length > 0 ? length : nil
    }

    /// Whether the player for the current channel is actually producing audio (not just buffering).
    var audioStarted: Bool {
        guard isPlaying, let current else { return false }
        return (current.xtraID != nil ? xtraPlayer : player).timeControlStatus == .playing
    }

    /// Bars for what is coming out of the speakers right now, read from the frames worked out
    /// ahead of time at the player's exact position; nil when nothing is playing.
    /// `ahead` seconds past the playing position: the bars are frames worked out in advance, so the
    /// visualizer can read slightly ahead to make up for the time its smoothing takes to show them.
    func spectrumNow(ahead: Double = 0) -> [Float]? {
        guard isPlaying, let current else { return nil }
        if current.xtraID != nil {
            guard xtraPlayer.timeControlStatus == .playing, let item = xtraPlayer.currentItem,
                  let file = (item.asset as? AVURLAsset)?.url else { return nil }
            return SpectrumTimeline.shared.levels(track: file, at: item.currentTime().seconds + ahead)
        }
        // The item's own timeline, not its date: the date jumps back each time the playlist window slides.
        guard player.timeControlStatus == .playing, let time = player.currentItem?.currentTime().seconds else { return nil }
        let levels = SpectrumTimeline.shared.levels(time: time + ahead)
        // The EQ went dark while a live channel played, with nothing to go on. Log the transitions
        // (once per dropout, once per recovery) with the timeline's state: `log show --predicate 'subsystem == "com.starplayrx.mac"'`.
        if (levels == nil) != eqDark {
            eqDark = levels == nil
            Self.log.notice("live EQ \(self.eqDark ? "dark" : "back", privacy: .public) ch=\(current.id, privacy: .public) t=\(time, privacy: .public) \(SpectrumTimeline.shared.state, privacy: .public)")
        }
        return levels
    }
    private static let log = Logger(subsystem: "com.starplayrx.mac", category: "eq")
    private var eqDark = false

    private func isPlayingXtra(_ id: String) -> Bool {
        isPlaying && current?.id == id && current?.xtraID != nil
    }

    private var artworkURL = ""
    private var artwork: MPMediaItemArtwork?

    private func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        guard let current else { center.nowPlayingInfo = nil; return }
        let np = nowPlaying[current.id]
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: np?.song ?? current.name,
            MPMediaItemPropertyArtist: np?.artist ?? "",
            MPMediaItemPropertyAlbumTitle: current.name,
            MPNowPlayingInfoPropertyIsLiveStream: true
        ]
        // Same art as the menu's Now Playing tile: album art when there is some, else the channel logo.
        let url = (np?.image).flatMap { $0.isEmpty ? nil : $0 } ?? current.imageURL
        if url == artworkURL, let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
        guard url != artworkURL else { return }
        artworkURL = url
        artwork = nil
        Task {
            guard let image = await ArtCache.shared.image(url, pixels: ArtCache.pixels(150)),
                  artworkURL == url else { return }
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            updateNowPlayingInfo()
        }
    }

    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { _ in
            Task { @MainActor in if let c = Radio.shared.current { Radio.shared.play(c) } }
            return .success
        }
        cc.pauseCommand.addTarget { _ in
            Task { @MainActor in Radio.shared.stop() }
            return .success
        }
        cc.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in Radio.shared.togglePlayPause() }
            return .success
        }
    }
}
