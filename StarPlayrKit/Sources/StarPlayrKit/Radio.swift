//
//  Radio.swift
//  StarPlayrKit
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
public final class Radio: ObservableObject {
    public static let shared = Radio()

    @Published public var status = "Not signed in"
    @Published public var isBusy = false
    @Published public var isLoggedIn = false
    @Published public var isPlaying = false
    @Published public var channels = [Channel]()
    @Published public var current: Channel?
    @Published public var nowPlaying = [String: NowPlaying]()
    /// Channels where the user clicked the artwork to see the show's art instead of the channel logo.
    /// Logo is the default; the choice is per channel and remembered.
    @Published public private(set) var showArtChannels = Set(UserDefaults.standard.stringArray(forKey: "showArtChannels") ?? [])

    /// Which art the now-playing tile shows.
    public enum ArtKind { case album, channel, show }

    /// Channels where the user clicked past the song's album art to the channel logo or show art
    /// (this session only). Without song art, `showArtChannels` decides instead.
    @Published public private(set) var artChoice = [String: ArtKind]()

    /// The art a channel has right now, in click order: album art, channel logo, show art.
    public func artKinds(_ id: String) -> [ArtKind] {
        guard let np = nowPlaying[id] else { return [.channel] }
        return (np.image.isEmpty ? [] : [.album]) + [.channel] + (np.showImage.isEmpty ? [] : [.show])
    }

    /// The art shown for a channel: song art unless the user clicked past it, else the show's art
    /// on channels where the user chose it, else the channel logo.
    public func shownArt(_ id: String) -> ArtKind {
        let kinds = artKinds(id)
        if kinds.contains(.album) {
            return artChoice[id].flatMap { kinds.contains($0) ? $0 : nil } ?? .album
        }
        return showArtChannels.contains(id) && kinds.contains(.show) ? .show : .channel
    }

    /// Now playing as shown: the image of `shownArt` (empty for the channel logo, which is drawn instead).
    public func displayed(_ id: String) -> NowPlaying? {
        guard var np = nowPlaying[id] else { return nil }
        switch shownArt(id) {
        case .album: break
        case .channel: np.image = ""
        case .show: np.image = np.showImage
        }
        return np
    }

    /// The art the current channel's tile shows now (album art, show art or the channel logo), nil
    /// when there is none.
    public var shownArtURL: String? {
        current.flatMap { ch in displayed(ch.id).map(\.image).flatMap { $0.isEmpty ? nil : $0 } ?? ch.imageURL }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Every art the current channel has (album art, channel logo, show art) with whether it's a logo,
    /// so the big versions are loaded before the user opens or cycles them.
    public var artCandidates: [(url: String, isLogo: Bool)] {
        guard let ch = current else { return [] }
        let np = nowPlaying[ch.id]
        return [(np?.image ?? "", false), (ch.imageURL, true), (np?.showImage ?? "", false)].filter { !$0.url.isEmpty }
    }

    /// Clicking the small artwork steps album art → channel logo → show art, skipping what the channel
    /// doesn't have. Returns false when there is nothing to switch to.
    @discardableResult
    public func cycleArt(_ id: String) -> Bool {
        let kinds = artKinds(id)
        guard kinds.contains(.album) else { return toggleShowArt(id) }
        guard kinds.count > 1, let i = kinds.firstIndex(of: shownArt(id)) else { return false }
        let next = kinds[(i + 1) % kinds.count]
        artChoice[id] = next == .album ? nil : next
        return true
    }

    /// Clicking the artwork switches between the channel logo and the show's art, for that channel only.
    /// Returns false when there is nothing to switch to (song art, or no show art).
    @discardableResult
    public func toggleShowArt(_ id: String) -> Bool {
        guard let np = nowPlaying[id], np.image.isEmpty, !np.showImage.isEmpty else { return false }
        if showArtChannels.contains(id) { showArtChannels.remove(id) } else { showArtChannels.insert(id) }
        UserDefaults.standard.set(Array(showArtChannels).sorted(), forKey: "showArtChannels")
        return true
    }
    /// Starred channels ("presets" on iOS; same key and starting set as the iOS app). Kept on this
    /// Mac only, not on the SiriusXM account.
    @Published public private(set) var presets = Set(UserDefaults.standard.stringArray(forKey: "SPXPresets") ?? ["2", "3", "4"])

    /// The star: adds the channel to the presets, or takes it out. Remembered.
    public func togglePreset(_ id: String) {
        if presets.contains(id) { presets.remove(id) } else { presets.insert(id) }
        UserDefaults.standard.set(Array(presets).sorted { Int($0) ?? 0 < Int($1) ?? 0 }, forKey: "SPXPresets")
    }
    /// Canadian account: the API is the same, the request locale is en-CA (as can.siriusxm.com sends).
    @Published public var localeIsCA = UserDefaults.standard.bool(forKey: "localeIsCA")
    /// True once sign-in has finished loading every channel, Xtra included.
    @Published public var channelsLoaded = false

    private let playback = PlaybackWorker.shared
    private var playbackID = UUID()
    private var liveTask: Task<Void, Never>?
    private var playbackState: PlaybackWorker.Snapshot {
        let state = playback.snapshot
        return state.id == playbackID ? state : .init()
    }
    private var pdtTimer: Timer?

    // Xtra channels: tracks are downloaded, decrypted and queued one after another.
    private let xtra = XtraClient()
    private var xtraTask: Task<Void, Never>?
    private var xtraNowPlaying = [String: NowPlaying]()
    private var liveIDs = [String: String]()   // live channel number -> entity id, for the lookAround feed
    private var xtraPeekedAt = [String: Date]()
    private var xtraPeekedTrack = [String: XtraTrack]()  // what the channel list shows, played first on tune
    private var xtraPeeking = false
    private var xtraFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("StarPlayrXtra/\(playbackID.uuidString)")
    }

    private init() {
        setupRemoteCommands()
        playback.onTrackChange { [weak self] id in
            Task { @MainActor in
                guard let self, self.playbackID == id else { return }
                self.xtraItemChanged()
            }
        }
    }

    // MARK: Login

    /// The player went up from the disk list before the network sign-in finished.
    private var shownFromCache = false

    /// Shows the player at once with the list kept on disk, before the network sign-in: launch
    /// doesn't wait on the server. `login` then signs in and tunes the last channel; if it fails,
    /// the app goes back to the sign-in screen. Returns false when there's no list to show.
    @discardableResult
    public func showCachedChannels() -> Bool {
        guard !isLoggedIn else { return true }
        let cached = Self.cachedChannels(locale: localeIsCA ? "en-CA" : "en-US")
        guard !cached.isEmpty else { return false }
        apply(cached)
        if let last = UserDefaults.standard.string(forKey: "lastChannel") {
            current = channels.first { $0.id == last }
        }
        status = "Signing in…"
        isLoggedIn = true
        shownFromCache = true
        return true
    }

    /// Signs in to the SiriusXM API; every channel (live and Xtra) comes from XtraClient.channels().
    /// The full list takes ~35 s (the server answers its 26 pages one after another), so the last
    /// list is kept on disk: it shows right after sign-in and the fresh one replaces it when it arrives.
    public func login(user: String, pass: String) async -> Bool {
        isBusy = true
        channelsLoaded = false
        defer { isBusy = false }
        status = "Signing in…"
        let locale = localeIsCA ? "en-CA" : "en-US"
        do {
            await xtra.setLocale(locale)
            try await xtra.signIn(user: user, pass: pass)
        } catch {
            status = error.localizedDescription
            if shownFromCache { shownFromCache = false; isLoggedIn = false }
            return false
        }
        Keychain.save(user: user, pass: pass)
        let cached = Self.cachedChannels(locale: locale)
        if !cached.isEmpty {
            apply(cached)
            isBusy = false
            await signedIn()
        } else {
            status = "Loading channels…"
        }
        let all: [XtraChannel]
        do {
            all = try await xtra.channels()
        } catch {
            if cached.isEmpty { status = error.localizedDescription; return false }
            return true
        }
        guard !all.isEmpty else {
            if cached.isEmpty { status = "Error reading channels."; return false }
            return true
        }
        Self.saveChannels(all, locale: locale)
        apply(all)
        if cached.isEmpty { await signedIn() }
        return true
    }

    private func apply(_ all: [XtraChannel]) {
        liveIDs = Dictionary(all.filter { !$0.isXtra }.map { ($0.number, $0.id) }) { first, _ in first }
        channels = all.map {
            Channel(id: $0.number, name: $0.name, category: $0.genre, imageURL: $0.imageURL, xtraID: $0.isXtra ? $0.id : nil)
        }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        // A refreshed list may carry new art URLs; keep `current` the list's own value so it still matches.
        if let id = current?.id, let fresh = channels.first(where: { $0.id == id }) { current = fresh }
    }

    private func signedIn() async {
        isLoggedIn = true
        shownFromCache = false
        channelsLoaded = true
        status = "Signed in"
        if let last = UserDefaults.standard.string(forKey: "lastChannel") {
            current = channels.first { $0.id == last }
            if let current, !isPlaying { play(current) }
        }
        await updatePDT()
        startPDTTimer()
    }

    private static func channelCache(locale: String) -> URL? {
        // In the app's own folder: the Mac app isn't sandboxed, so Caches is the user's shared one.
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "StarPlayrX") else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("channels-\(locale).json")
    }

    private static func cachedChannels(locale: String) -> [XtraChannel] {
        guard let url = channelCache(locale: locale), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([XtraChannel].self, from: data)) ?? []
    }

    private static func saveChannels(_ all: [XtraChannel], locale: String) {
        guard let url = channelCache(locale: locale), let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public func signOut() {
        stop()
        pdtTimer?.invalidate()
        Keychain.delete()
        // The list is per account; the next one shouldn't see this one's.
        for locale in ["en-US", "en-CA"] { if let url = Self.channelCache(locale: locale) { try? FileManager.default.removeItem(at: url) } }
        Task { await xtra.signOut() }
        isLoggedIn = false
        channelsLoaded = false
        channels = []
        lookAround = [:]
        current = nil
        status = "Not signed in"
    }

    /// Canada or US. Takes effect at the next sign-in.
    public func setRegion(ca: Bool) {
        localeIsCA = ca
        UserDefaults.standard.set(ca, forKey: "localeIsCA")
    }

    // MARK: Playback

    public func play(_ channel: Channel) {
        haltXtra()
        liveTask?.cancel()
        playbackID = UUID()
        let id = playbackID
        playback.begin(id: id, xtra: channel.xtraID != nil, folder: xtraFolder)
        current = channel
        UserDefaults.standard.set(channel.id, forKey: "lastChannel")
        // A tune the user asked for starts the stall count over; a re-tune by the watchdog keeps it.
        if retuning { retuning = false } else { recoveryAttempts = 0 }
        startWatchdog()
        if let xtraID = channel.xtraID {
            playXtra(channel, id: xtraID)
            return
        }
        liveTask = Task {
            guard let liveID = liveIDs[channel.id] else { status = "Channel \(channel.id) is not available."; stop(); return }
            let live: URL
            do { live = try await xtra.liveStream(channelID: liveID) } catch {
                guard !Task.isCancelled, playbackID == id else { return }
                status = error.localizedDescription; stop(); return
            }
            guard !Task.isCancelled, playbackID == id else { return }
            isPlaying = true
            playback.loadLive(live, client: xtra, id: id)
            await updatePDT()
        }
    }

    public func togglePlayPause() {
        if isPlaying { stop() } else if let current { play(current) }
    }

    /// Moves the sound to the output `uid` with `route` (on the Mac: a display's speakers, see
    /// `DisplayAudio` there). Moves asked for while one is under way are run after it, newest only,
    /// and the stall watchdog leaves the fade alone.
    public func routeAudio(toOutput uid: String, via route: @escaping (String) async -> Void) {
        pendingOutputUID = uid
        guard routeTask == nil else { return }
        routeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                routeTask = nil
                silentSince = nil
            }
            while let uid = pendingOutputUID {
                pendingOutputUID = nil
                await route(uid)
            }
        }
    }
    private var pendingOutputUID: String?
    private var routeTask: Task<Void, Never>?


    public func stop() {
        stopWatchdog()
        haltXtra()
        liveTask?.cancel()
        liveTask = nil
        playbackID = UUID()
        playback.begin(id: playbackID, xtra: false, folder: xtraFolder)
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
    /// on after `stallSeconds` of it. An Xtra channel mid-download does not count either: the queue can
    /// sit empty for longer than `stallSeconds` while the next track is still coming down a slow link,
    /// and re-tuning a healthy channel over that is what killed it.
    private var isSilent: Bool {
        guard let current else { return false }
        guard current.xtraID == nil else {
            return playbackState.xtraStatus != .playing && playbackState.queueCount == 0 && xtraTask == nil
        }
        return playbackState.liveStatus != .playing
    }

    private func checkPlayback() {
        // A device handoff is not a dead stream; do not retune it during the fade.
        guard routeTask == nil else { silentSince = nil; return }
        // A live tune sets isPlaying only after the stream URL comes back; stop() is what ends the watchdog.
        guard isPlaying, let channel = current else { silentSince = nil; return }
        guard isSilent else { silentSince = nil; recoveryAttempts = 0; return }
        let since = silentSince ?? Date()
        silentSince = since
        guard Date().timeIntervalSince(since) >= Self.stallSeconds else { return }
        silentSince = nil
        guard recoveryAttempts < Self.maxRecoveryAttempts else {
            Self.playLog.error("playback gave up ch=\(channel.id) after \(self.recoveryAttempts) tries")
            stop()
            status = "Playback stopped. Press play to try again."
            return
        }
        recoveryAttempts += 1
        Self.playLog.notice("playback stalled ch=\(channel.id) re-tuning, try \(self.recoveryAttempts)")
        retuning = true
        play(channel)
    }
    private static let playLog = Log(subsystem: "com.starplayrx.mac", category: "playback")

    // MARK: Xtra playback

    private func printXtra(_ line: String) {
        Log(subsystem: "com.starplayrx.mac", category: "xtra").notice("\(line)")
    }

    private func playXtra(_ channel: Channel, id: String) {
        isPlaying = true
        // Tuning again returns a different track than the peek, so start with the peeked track
        // the channel list is showing (from its beginning), then continue with the tuned queue.
        let peeked = xtraPeekedTrack.removeValue(forKey: channel.id).map {
            XtraTrack(id: $0.id, artist: $0.artist, title: $0.title, url: $0.url, keyID: $0.keyID,
                      imageURL: $0.imageURL, startOffset: 0)
        }
        printXtra("XTRA play \(channel.id) shown=\(nowPlaying[channel.id]?.song ?? "nil") peeked=\(peeked?.title ?? "nil")")
        if peeked == nil {
            xtraNowPlaying[channel.id] = nil
            nowPlaying[channel.id] = nil
        }
        updateNowPlayingInfo()
        let session = playbackID
        let folder = xtraFolder
        xtraTask = Task {
            var pending = [XtraTrack]()
            var token: String?
            var seen = Set<String>()
            var first = true
            if let peeked {
                seen.insert(peeked.id)
                do {
                    let file = try await xtra.download(peeked, into: folder)
                    if !Task.isCancelled, playbackID == session {
                        SpectrumTimeline.shared.analyze(track: file)
                        await playback.enqueue(peeked, file: file, first: true, id: session)
                        first = false
                    }
                } catch {
                    printXtra("XTRA peeked download failed \(channel.id) \(peeked.title): \(error.localizedDescription) url=\(peeked.url)")
                }
            }
            do {
                while !Task.isCancelled {
                    // Keep one track playing and one ready behind it.
                    if playbackState.queueCount > 1 {
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
                    let file = try await xtra.download(track, into: folder)
                    guard !Task.isCancelled, playbackID == session else { break }
                    SpectrumTimeline.shared.analyze(track: file, from: first ? track.startOffset : 0)
                    await playback.enqueue(track, file: file, first: first, id: session)
                    first = false
                }
            } catch is CancellationError {
            } catch {
                printXtra("Xtra playback error: \(error.localizedDescription)")
                if first, !Task.isCancelled, playbackID == session { stop() }
            }
        }
    }

    private func haltXtra() {
        // The list keeps showing the song that was playing, so tuning back in should play that song.
        if let track = playbackState.track, let current, current.xtraID != nil {
            xtraPeekedTrack[current.id] = track
        }
        xtraTask?.cancel()
        xtraTask = nil
    }

    /// Shows the queued track that just started and deletes files of tracks that have finished.
    fileprivate func xtraItemChanged() {
        guard let track = playbackState.track, let current, current.xtraID != nil else { return }
        let np = NowPlaying(artist: track.artist, song: track.title, image: track.imageURL)
        // Called from both the queue observer and playXtra for the same item: log the track once.
        if xtraNowPlaying[current.id] != np { printXtra("XTRA playing \(current.id) \(track.artist) – \(track.title)") }
        xtraNowPlaying[current.id] = np
        nowPlaying[current.id] = np
        applyHeard()
        updateNowPlayingInfo()
    }

    // MARK: Now playing (PDT)

    private func startPDTTimer() {
        pdtTimer?.invalidate()
        pdtTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in await Radio.shared.updatePDT() }
        }
    }

    public func updatePDT() async {
        // One source for every live row, tuned or not: the newer API (lookAround).
        // The player's date runs ahead of the stream's real PDT (segments are tagged 10 s but hold
        // ~9.75 s, so the gap grows to ~8 s). The song list was matched to the player's date, so it
        // ran that far ahead of the music; hold it back by the measured gap.
        if current?.xtraID == nil, playbackState.liveStatus == .playing, let at = playbackState.liveDate,
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
        // Only when something changed: every assignment redraws every row of the channel list.
        let merged = lookAround.merging(xtraNowPlaying) { live, _ in live }
        if merged != nowPlaying { nowPlaying = merged }
        applyHeard()
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
    public nonisolated static func keepingArt(_ new: NowPlaying, of old: NowPlaying?) -> NowPlaying {
        guard new.image.isEmpty, let old, !old.image.isEmpty, old.artist == new.artist, old.song == new.song else { return new }
        var kept = new
        kept.image = old.image
        return kept
    }
    private var pendingPeeks = [String: XtraTrack]()
    private var peekFlushScheduled = false

    /// What is actually coming out of the speakers: the Xtra track in the player, or the live channel's PDT.
    /// Shazam's names stand in for the station's when those were blank or wrong (see `hear`).
    public var playingNow: NowPlaying? {
        guard isPlaying, let current else { return nil }
        guard current.xtraID != nil else { return nowPlaying[current.id] }
        guard let track = playbackState.track else { return nil }
        return corrected(NowPlaying(artist: track.artist, song: track.title, image: track.imageURL), channel: current.id)
    }

    /// The station's own names for what is on now, before Shazam's correction. A live channel with no
    /// cut at all is a blank one.
    public var stationNowPlaying: NowPlaying? {
        guard isPlaying, let current else { return nil }
        guard current.xtraID != nil else { return lookAround[current.id] ?? NowPlaying() }
        return playbackState.track.map { NowPlaying(artist: $0.artist, song: $0.title, image: $0.imageURL) }
    }

    /// What Shazam heard on the channel playing now, standing in for the station's artist and title
    /// when those were blank or named another song: in Now Playing, the lock screen and for the
    /// lyrics. Only while the station still shows the names it corrected (`station`), so the
    /// station moving on to its next cut drops it.
    private struct Heard { let channel: String; let station: String; let artist: String; let song: String; let startedAt: Date? }
    private var heard: Heard?

    /// Shazam's names (and, when it timed the record, the song's real start) in place of the station's.
    public func hear(artist: String, song: String, startedAt: Date?) {
        guard let current, let station = stationNowPlaying else { return }
        heard = Heard(channel: current.id, station: LyricsStore.key(station.artist, station.song),
                      artist: artist, song: song, startedAt: startedAt)
        LyricSync.log.notice("now playing ch=\(current.id): station \"\(station.artist) – \(station.song)\" -> Shazam \"\(artist) – \(song)\"")
        applyHeard()
    }

    private func applyHeard() {
        guard let current, let station = stationNowPlaying else { return }
        let np = corrected(station, channel: current.id)
        guard np != station, nowPlaying[current.id] != np else { return }
        nowPlaying[current.id] = np
        updateNowPlayingInfo()
    }

    private func corrected(_ np: NowPlaying, channel: String) -> NowPlaying {
        guard let heard, heard.channel == channel, heard.station == LyricsStore.key(np.artist, np.song) else { return np }
        var np = np
        np.artist = heard.artist
        np.song = heard.song
        np.image = ""   // the station's art is for the song it named, not this one: the channel logo instead
        np.startedAt = heard.startedAt ?? np.startedAt
        return np
    }

    /// Seconds into the song that's playing, for the time-synced lyrics. Xtra tracks are whole
    /// files in the player, so the player knows. A live channel's stream has no song boundaries:
    /// the cut's `validFrom` is the song's start in stream time, and the music runs `streamLag`
    /// behind real time, so now minus that lag minus the start is how far into the song it is.
    public var trackPosition: TimeInterval? {
        guard isPlaying else { return nil }
        guard current?.xtraID != nil else {
            guard let np = current.flatMap({ nowPlaying[$0.id] }), let started = np.startedAt,
                  let heard = heardDate else { return nil }
            // The shift measured from the audio for this very song when there is one, and the
            // same constant for everything else only until that lands.
            let lead = LyricSync.shared.shift(forKey: LyricsStore.key(np.artist, np.song)) ?? Self.liveLyricsLead
            let at = heard.timeIntervalSince(started) + lead
            // A late cut stamp or a large negative measured shift can put the opening seconds just
            // below zero: clamp them rather than showing nothing. Past that, a talk segment or a
            // stale cut runs for hours and these aren't its lyrics.
            return (0...900).contains(at) ? at : (at < 0 ? 0 : nil)
        }
        let state = playbackState
        guard state.xtraStatus != .paused else { return nil }
        let at = state.xtraTime
        guard at.isFinite else { return nil }
        // The player knows where the file is; Shazam says where that is in the record the lyrics
        // are timed to, and a line the user clicked moves the words against it over both.
        let file = state.file
        let shazam = file.flatMap { LyricSync.shared.xtraShift(for: $0) } ?? 0
        guard let np = playingNow else { return at + shazam }
        return at + (LyricSync.shared.pinnedShift(forKey: LyricsStore.key(np.artist, np.song)) ?? shazam)
    }

    /// The Xtra file in the player and the player's position in it, for matching with Shazam.
    public var xtraNow: (file: URL, at: Double)? {
        let state = playbackState
        guard isPlaying, current?.xtraID != nil, state.xtraStatus == .playing,
              let file = state.file else { return nil }
        let at = state.xtraTime
        return at.isFinite ? (file, at) : nil
    }


    /// Broadcast time of the audio coming out of the speakers right now on a live channel: the
    /// player's own date for those frames, put back on the stream's real PROGRAM-DATE-TIME. This is
    /// what both the song list and the lyrics are matched against, so neither runs ahead of the
    /// music when the player buffers, is paused, or is rewound.
    private var heardDate: Date? {
        guard current?.xtraID == nil, let at = playbackState.liveDate else { return nil }
        return SpectrumTimeline.shared.realDate(at: at) ?? at.addingTimeInterval(-streamLag)
    }

    /// Seconds added to where the cut's timestamp says we are. A live cut is stamped a little
    /// before the recording's own zero (the station fades in over the end of the last song, and the
    /// stamp is published early), so a small negative trim often lands closer than zero — but the
    /// real answer is measured from the audio (Shazam, then the aligner) within one decoded segment,
    /// so this is only the fallback until that lands, and zero is the honest one. How far is per
    /// song — a radio edit is cut differently from the record LRCLIB has — `defaults write
    /// com.starplayrx.mac lyricsLiveLead -float -1` (or 0, or -3) moves it without a rebuild.
    public static var liveLyricsLead: TimeInterval {
        UserDefaults.standard.object(forKey: "lyricsLiveLead") as? Double ?? 0
    }

    /// Length of the Xtra track in the player, which sharpens LRCLIB's matching. Nil on live channels.
    public var trackDuration: TimeInterval? {
        guard current?.xtraID != nil else { return nil }
        let length = playbackState.duration
        return length.isFinite && length > 0 ? length : nil
    }

    /// Whether the player for the current channel is actually producing audio (not just buffering).
    public var audioStarted: Bool {
        guard isPlaying, let current else { return false }
        return (current.xtraID != nil ? playbackState.xtraStatus : playbackState.liveStatus) == .playing
    }

    /// Bars for what is coming out of the speakers right now, read from the frames worked out
    /// ahead of time at the player's exact position; nil when nothing is playing.
    /// `ahead` seconds past the playing position: the bars are frames worked out in advance, so the
    /// visualizer can read slightly ahead to make up for the time its smoothing takes to show them.
    public func spectrumNow(ahead: Double = 0) -> [Float]? {
        guard isPlaying, let current else { return nil }
        let state = playbackState
        if current.xtraID != nil { return state.spectrum(ahead: ahead) }
        // The item's own timeline, not its date: the date jumps back each time the playlist window slides.
        guard state.liveStatus == .playing else { return nil }
        let time = state.liveTime
        let levels = state.spectrum(ahead: ahead)
        // The EQ went dark while a live channel played, with nothing to go on. Log the transitions
        // (once per dropout, once per recovery) with the timeline's state: `log show --predicate 'subsystem == "com.starplayrx.mac"'`.
        if (levels == nil) != eqDark {
            eqDark = levels == nil
            Self.log.notice("live EQ \(self.eqDark ? "dark" : "back") ch=\(current.id) t=\(time) \(SpectrumTimeline.shared.state)")
        }
        return levels
    }
    private static let log = Log(subsystem: "com.starplayrx.mac", category: "eq")
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
