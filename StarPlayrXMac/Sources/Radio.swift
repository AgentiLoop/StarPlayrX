import Foundation
import AVFoundation
import MediaPlayer
import Combine
import StarPlayrRadioKit

struct Channel: Identifiable, Hashable {
    let id: String          // channel number
    let name: String
    let category: String
    let imageURL: String
    var xtraID: String? = nil   // set for Xtra channels (streamed track by track)
}

struct NowPlaying: Equatable {
    var artist = ""
    var song = ""
    var image = ""
}

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
    @Published var localeIsCA = UserDefaults.standard.bool(forKey: "localeIsCA")
    /// True once sign-in has finished loading every channel, Xtra included (or Xtra failed).
    @Published var channelsLoaded = false

    private var port: UInt16 = 9999
    private var serverStarted = false
    private let player = AVPlayer()
    private var pdtTimer: Timer?

    // Xtra channels: tracks are downloaded, decrypted and queued one after another.
    private let xtra = XtraClient()
    private let xtraPlayer = AVQueuePlayer()
    private var xtraTask: Task<Void, Never>?
    private var xtraTracks = [AVPlayerItem: XtraTrack]()
    private var xtraNowPlaying = [String: NowPlaying]()
    private var xtraObserver: AnyCancellable?
    private var xtraPeekedAt = [String: Date]()
    private var xtraPeekedTrack = [String: XtraTrack]()  // what the channel list shows, played first on tune
    private var xtraPeeking = false
    private let xtraFolder = FileManager.default.temporaryDirectory.appendingPathComponent("StarPlayrXtra")

    private var base: String { "http://127.0.0.1:\(port)/api/v3" }

    private init() {
        setupRemoteCommands()
        xtraObserver = xtraPlayer.publisher(for: \.currentItem)
            .receive(on: DispatchQueue.main)
            .sink { _ in Task { @MainActor in Radio.shared.xtraItemChanged() } }
    }

    // MARK: Server

    private func startServerIfNeeded() async {
        if serverStarted, await text("ping") == "pong" { return }
        for p in port..<65000 where portIsOpen(UInt16(p)) {
            port = UInt16(p)
            break
        }
        startServer(port)
        preflightConfig(location: localeIsCA ? "CA" : "US")
        for _ in 0..<20 {
            if await text("ping") == "pong" { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        serverStarted = true
    }

    // MARK: Login

    func login(user: String, pass: String) async -> Bool {
        isBusy = true
        channelsLoaded = false
        defer { isBusy = false }
        status = "Starting…"
        await startServerIfNeeded()
        _ = await text(localeIsCA ? "ca" : "us")

        status = "Signing in…"
        let result = await post("login", ["user": user, "pass": pass])
        // StarPlayrRadioKit caches the password in UserDefaults; the Mac app keeps it only in the Keychain.
        UserDefaults.standard.removeObject(forKey: "pass")

        guard let result, result["success"] as? Bool == true else {
            status = (result?["message"] as? String) ?? "Login failed. Check your connection."
            return false
        }
        Keychain.save(user: user, pass: pass)

        status = "Loading channels…"
        _ = await post("session", ["channelid": "siriushits1"])
        guard let data = await post("channels", ["channeltype": ""])?["data"] as? [String: Any], !data.isEmpty else {
            status = "Error reading channels."
            return false
        }

        channels = data.compactMap { key, value in
            guard let v = value as? [String: Any],
                  let number = v["channelNumber"] as? String,
                  var name = v["name"] as? String else { return nil }
            for prefix in ["SiriusXM ", "Sirius XM ", "Sirius ", "SXM ", "SPX "] {
                name = name.replacingOccurrences(of: prefix, with: "")
            }
            return Channel(id: number, name: name,
                           category: v["category"] as? String ?? "",
                           imageURL: v["mediumImage"] as? String ?? "")
        }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }

        isLoggedIn = true
        status = "Signed in"
        if let last = UserDefaults.standard.string(forKey: "lastChannel") {
            current = channels.first { $0.id == last }
        }
        await updatePDT()
        startPDTTimer()
        Task { await loadXtraChannels(user: user, pass: pass) }
        return true
    }

    /// Xtra channels come from SiriusXM's newer API; if that fails the live channels still work.
    private func loadXtraChannels(user: String, pass: String) async {
        defer { if isLoggedIn { channelsLoaded = true } }
        do {
            try await xtra.signIn(user: user, pass: pass)
            let all = try await xtra.channels()
            let xtras = all.filter(\.isXtra).map {
                Channel(id: $0.number, name: $0.name, category: $0.genre, imageURL: $0.imageURL, xtraID: $0.id)
            }
            // Live channels get the same full square tile art as Xtra channels when the newer API has it.
            var tiles = [String: String]()
            for ch in all where !ch.isXtra && !ch.imageURL.isEmpty { tiles[ch.number] = ch.imageURL }
            guard isLoggedIn else { return }
            let withTiles = channels.map { ch in
                tiles[ch.id].map { Channel(id: ch.id, name: ch.name, category: ch.category, imageURL: $0, xtraID: ch.xtraID) } ?? ch
            }
            let live = Set(withTiles.map(\.id))
            channels = (withTiles + xtras.filter { !live.contains($0.id) })
                .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            if let id = current?.id ?? UserDefaults.standard.string(forKey: "lastChannel") {
                current = channels.first { $0.id == id }   // pick up the new art for the current channel too
            }
            await refreshXtraNowPlaying()
        } catch {
            print("Xtra channels unavailable: \(error.localizedDescription)")
        }
    }

    func signOut() {
        stop()
        pdtTimer?.invalidate()
        Keychain.delete()
        Task { await xtra.signOut() }
        isLoggedIn = false
        channelsLoaded = false
        channels = []
        current = nil
        status = "Not signed in"
    }

    func setRegion(ca: Bool) {
        localeIsCA = ca
        UserDefaults.standard.set(ca, forKey: "localeIsCA")
        if serverStarted { Task { _ = await text(ca ? "ca" : "us") } }
    }

    // MARK: Playback

    func play(_ channel: Channel) {
        haltXtra()
        current = channel
        UserDefaults.standard.set(channel.id, forKey: "lastChannel")
        if let xtraID = channel.xtraID {
            player.pause()
            player.replaceCurrentItem(with: nil)
            playXtra(channel, id: xtraID)
            return
        }
        Task {
            await startServerIfNeeded()
            guard let url = URL(string: "http://localhost:\(port)/api/v3/m3u/\(channel.id).m3u8") else { return }
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.play()
            isPlaying = true
            await updatePDT()
        }
    }

    func togglePlayPause() {
        if isPlaying { stop() } else if let current { play(current) }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        haltXtra()
        isPlaying = false
        updateNowPlayingInfo()
    }

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
        try? FileManager.default.removeItem(at: xtraFolder)
    }

    /// Shows the queued track that just started and deletes files of tracks that have finished.
    fileprivate func xtraItemChanged() {
        let queued = Set(xtraPlayer.items())
        for (item, track) in xtraTracks where !queued.contains(item) {
            xtraTracks[item] = nil
            try? FileManager.default.removeItem(at: xtraFolder.appendingPathComponent("\(track.id).aac"))
        }
        guard let item = xtraPlayer.currentItem, let track = xtraTracks[item], let current, current.xtraID != nil else { return }
        print("XTRA playing \(current.id) \(track.artist) – \(track.title)")
        let np = NowPlaying(artist: track.artist, song: track.title, image: track.imageURL)
        xtraNowPlaying[current.id] = np
        nowPlaying[current.id] = np
        updateNowPlayingInfo()
    }

    // MARK: Now playing (PDT)

    private func startPDTTimer() {
        pdtTimer?.invalidate()
        pdtTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in await Radio.shared.updatePDT() }
        }
    }

    func updatePDT() async {
        guard let cache = await get("pdt")?["data"] as? [String: Any] else { return }
        var np = [String: NowPlaying]()
        for (key, value) in cache {
            if let v = value as? [String: String] {
                np[key] = NowPlaying(artist: v["artist"] ?? "", song: v["song"] ?? "", image: v["image"] ?? "")
            }
        }
        nowPlaying = np.merging(xtraNowPlaying) { live, _ in live }
        updateNowPlayingInfo()
        Task { await refreshXtraNowPlaying() }
    }

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
            .filter { xtraPeekedAt[$0.id]! < stale }
            .sorted { xtraPeekedAt[$0.id]! < xtraPeekedAt[$1.id]! }
            .prefix(30))
        guard !batch.isEmpty else { return }
        let client = xtra
        await withTaskGroup(of: (String, XtraTrack?).self) { group in
            for (i, ch) in batch.enumerated() {
                if i >= 12, let r = await group.next() { applyXtraPeek(r.0, r.1) }
                group.addTask { (ch.id, try? await client.peek(channelID: ch.xtraID!)) }
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
            let batch = tracks.mapValues { NowPlaying(artist: $0.artist, song: $0.title, image: $0.imageURL) }
            xtraPeekedTrack.merge(tracks) { _, new in new }
            xtraNowPlaying.merge(batch) { _, new in new }
            nowPlaying.merge(batch) { _, new in new }
        }
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

    /// Whether the player for the current channel is actually producing audio (not just buffering).
    var audioStarted: Bool {
        guard isPlaying, let current else { return false }
        return (current.xtraID != nil ? xtraPlayer : player).timeControlStatus == .playing
    }

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
        let url = np?.image.isEmpty == false ? np!.image : current.imageURL
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

    // MARK: Local server HTTP helpers

    private func text(_ path: String) async -> String? {
        guard let url = URL(string: "\(base)/\(path)") else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 2)
        req.httpMethod = "GET"
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func get(_ path: String) async -> [String: Any]? {
        guard let url = URL(string: "\(base)/\(path)") else { return nil }
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func post(_ path: String, _ body: [String: Any]) async -> [String: Any]? {
        guard let url = URL(string: "\(base)/\(path)") else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Port finder

    private func portIsOpen(_ port: in_port_t) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd != -1 else { return false }
        defer { Darwin.shutdown(fd, SHUT_RDWR); close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound != -1 && listen(fd, SOMAXCONN) != -1
    }
}
