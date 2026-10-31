import Foundation
import AVFoundation
import MediaPlayer
import StarPlayrRadioKit

struct Channel: Identifiable, Hashable {
    let id: String          // channel number
    let name: String
    let category: String
    let imageURL: String
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

    private var port: UInt16 = 9999
    private var serverStarted = false
    private let player = AVPlayer()
    private var pdtTimer: Timer?

    private var base: String { "http://127.0.0.1:\(port)/api/v3" }

    private init() {
        setupRemoteCommands()
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
        return true
    }

    func signOut() {
        stop()
        pdtTimer?.invalidate()
        Keychain.delete()
        isLoggedIn = false
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
        current = channel
        UserDefaults.standard.set(channel.id, forKey: "lastChannel")
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
        isPlaying = false
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
        nowPlaying = np
        updateNowPlayingInfo()
    }

    private func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        guard let current else { center.nowPlayingInfo = nil; return }
        let np = nowPlaying[current.id]
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: np?.song ?? current.name,
            MPMediaItemPropertyArtist: np?.artist ?? "",
            MPMediaItemPropertyAlbumTitle: current.name,
            MPNowPlayingInfoPropertyIsLiveStream: true
        ]
        center.playbackState = isPlaying ? .playing : .paused
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
