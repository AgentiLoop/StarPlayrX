import Foundation
import CommonCrypto

/// SiriusXM Xtra channels. They exist only in SiriusXM's current API (api.edge-gateway.siriusxm.com),
/// not the legacy player API that StarPlayrRadioKit uses, so they are fetched and played here.
/// An Xtra channel is a queue of individual tracks; each track is an encrypted HLS clip with its own key.

struct XtraChannel {
    let id: String          // entity id (guid)
    let number: String
    let name: String
    let genre: String
    let imageURL: String
    var isXtra = true       // false: a live channel, listed only for its square tile art
}

struct XtraTrack {
    let id: String
    let artist: String
    let title: String
    let url: String         // master playlist
    let keyID: String
    let imageURL: String
    let startOffset: Double // seconds; non-zero only for the track already playing when tuned
}

enum XtraError: LocalizedError {
    case http(Int, String)
    case badResponse(String)
    var errorDescription: String? {
        switch self {
        case .http(let code, let path): return "Xtra request failed (\(code)): \(path)"
        case .badResponse(let what): return "Unexpected Xtra response: \(what)"
        }
    }
}

actor XtraClient {
    private static let api = "https://api.edge-gateway.siriusxm.com"
    private static let imageService = "https://imgsrv-sxm-prod-device.streaming.siriusxm.com/"
    private static let trackArt = "https://siriusxm-priprodart.akamaized.net/"
    private static let lookAround = "https://lookaround-cache-prod.streaming.siriusxm.com/playbackservices/v1/live/lookAround?delta="
    // "All channels" curated grouping, the same one the SiriusXM web player shows.
    private static let allChannelsEntity = "403ab6a5-d3c9-4c2a-a722-a94a6a5fd056"
    private static let allChannelsContainer = "3JoBfOCIwo6FmTpzM1S2H7"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0.1 Safari/605.1.15"

    private let session = URLSession(configuration: .ephemeral)
    private var user = ""
    private var pass = ""
    private var token: String?
    private var expires = Date.distantPast
    private var lookAroundChannels = [String: [String: Any]]()
    private var lookAroundFetched = Date.distantPast

    // MARK: Sign in

    func signIn(user: String, pass: String) async throws {
        self.user = user
        self.pass = pass
        token = nil
        try await authenticate()
    }

    func signOut() {
        user = ""; pass = ""; token = nil; expires = .distantPast
    }

    private func authenticate() async throws {
        let device = try await json("POST", "/device/v1/devices", body: [
            "devicePlatform": "web-desktop",
            "deviceAttributes": ["browser": ["browserVersion": "27.0.1", "browser": "Safari", "userAgent": Self.userAgent,
                                             "sdk": "web", "app": "web", "sdkVersion": "18.3", "appVersion": "18.3"]]
        ], bearer: nil)
        guard let deviceGrant = device["grant"] as? String else { throw XtraError.badResponse("device grant") }

        let anon = try await json("POST", "/session/v1/sessions/anonymous", body: true, bearer: deviceGrant)
        guard let anonToken = anon["accessToken"] as? String else { throw XtraError.badResponse("anonymous session") }

        let auth = try await json("POST", "/identity/v1/identities/authenticate/password",
                                  body: ["handle": user, "password": pass], bearer: anonToken)
        guard let authGrant = auth["grant"] as? String else { throw XtraError.badResponse("password grant") }

        let session = try await json("POST", "/session/v1/sessions/authenticated", body: true, bearer: authGrant)
        guard let access = session["accessToken"] as? String else { throw XtraError.badResponse("authenticated session") }
        token = access
        expires = Self.date(session["accessTokenExpiresAt"] as? String) ?? Date().addingTimeInterval(30 * 60)
    }

    private func bearer() async throws -> String {
        if token == nil || Date() > expires.addingTimeInterval(-300) { try await authenticate() }
        guard let token else { throw XtraError.badResponse("no access token") }
        return token
    }

    // MARK: Channels

    func channels() async throws -> [XtraChannel] {
        let auth = try await bearer()
        var result = [XtraChannel]()
        var seen = Set<String>()
        var offset = 0
        // The API returns at most 30 items per page; fetch pages in parallel batches until one comes back empty.
        while offset < 3000 {
            let pages = try await withThrowingTaskGroup(of: (Int, [[String: Any]]).self) { group in
                for i in 0..<6 {
                    let o = offset + i * 30
                    // A page the server fails on (it sometimes answers 500) is retried once, then
                    // treated as the end of the list, so one bad page doesn't lose every tile.
                    group.addTask {
                        if let items = try? await self.channelPage(offset: o, bearer: auth) { return (o, items) }
                        try await Task.sleep(nanoseconds: 500_000_000)
                        return (o, (try? await self.channelPage(offset: o, bearer: auth)) ?? [])
                    }
                }
                var pages = [(Int, [[String: Any]])]()
                for try await page in group { pages.append(page) }
                return pages.sorted { $0.0 < $1.0 }
            }
            for (_, items) in pages {
                for item in items {
                    guard let ch = Self.channel(from: item), seen.insert(ch.id).inserted else { continue }
                    result.append(ch)
                }
            }
            if pages.contains(where: { $0.1.isEmpty }) { break }
            offset += 6 * 30
        }
        return result
    }

    private func channelPage(offset: Int, bearer: String) async throws -> [[String: Any]] {
        var c = URLComponents(string: Self.api + "/relationship/v1/container/all-channels")!
        c.queryItems = [
            .init(name: "entityId", value: Self.allChannelsEntity),
            .init(name: "entityType", value: "curated-grouping"),
            .init(name: "containerId", value: Self.allChannelsContainer),
            .init(name: "maxResponses", value: "30"),
            .init(name: "offset", value: String(offset)),
            .init(name: "locale", value: "en-US"),
            .init(name: "useCuratedContext", value: "false"),
            .init(name: "supportedMediaType", value: "AUDIO"),
            .init(name: "setStyle", value: "small_list"),
            .init(name: "unentitledContent", value: "lock"),
            .init(name: "preferredImageVariant", value: "default"),
            .init(name: "setResponseStructure", value: "default"),
        ]
        let page = try await json("GET", c.url!.absoluteString, body: nil, bearer: bearer)
        let sets = (page["container"] as? [String: Any])?["sets"] as? [[String: Any]] ?? []
        return sets.flatMap { $0["items"] as? [[String: Any]] ?? [] }
    }

    private static func channel(from item: [String: Any]) -> XtraChannel? {
        guard let entity = item["entity"] as? [String: Any],
              let type = entity["type"] as? String, type == "channel-xtra" || type == "channel-linear",
              let id = entity["id"] as? String,
              let name = ((entity["texts"] as? [String: Any])?["title"] as? [String: Any])?["default"] as? String
        else { return nil }
        let deco = item["decorations"] as? [String: Any] ?? [:]
        if type == "channel-xtra", deco["unentitled"] as? Bool == true { return nil }
        guard let number = deco["channelNumber"].map({ "\($0)" }) else { return nil }
        let tile = ((entity["images"] as? [String: Any])?["tile"] as? [String: Any])?["aspect_1x1"] as? [String: Any]
        let key = ((tile?["preferred"] ?? tile?["default"]) as? [String: Any])?["url"] as? String
        return XtraChannel(id: id, number: number, name: name, genre: deco["genre"] as? String ?? "",
                           imageURL: key.map { imageURL(key: $0) } ?? "", isXtra: type == "channel-xtra")
    }

    private static func imageURL(key: String, size: Int = 128) -> String {
        let spec: [String: Any] = ["key": key, "edits": [["resize": ["width": size, "height": size]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: spec, options: .withoutEscapingSlashes) else { return "" }
        return imageService + data.base64EncodedString()
    }

    // MARK: Tune

    /// Returns the next few tracks of an Xtra channel. Pass the returned token back to continue the queue.
    func tune(channelID: String, sequenceToken: String? = nil) async throws -> (tracks: [XtraTrack], token: String?) {
        var body: [String: Any] = ["id": channelID, "type": "channel-xtra", "hlsVersion": "V3",
                                   "manifestVariant": "FULL", "mtcVersion": "V2"]
        if let sequenceToken { body["sequenceToken"] = sequenceToken }
        let tune = try await json("POST", "/playback/play/v1/tuneSource", body: body, bearer: try await bearer())

        let tracks: [XtraTrack] = (tune["streams"] as? [[String: Any]] ?? []).compactMap { stream in
            let urls = stream["urls"] as? [[String: Any]] ?? []
            guard let id = stream["id"] as? String,
                  let url = (urls.first { $0["isPrimary"] as? Bool == true } ?? urls.first)?["url"] as? String
            else { return nil }
            let xtra = (stream["metadata"] as? [String: Any])?["xtra"] as? [String: Any] ?? [:]
            let item = (xtra["items"] as? [[String: Any]])?.first ?? [:]
            let tile = ((item["images"] as? [String: Any])?["tile"] as? [String: Any])?["aspect_1x1"] as? [String: Any]
            let art = ((tile?["preferredImage"] ?? tile?["defaultImage"]) as? [String: Any])?["url"] as? String
            return XtraTrack(id: id,
                             artist: item["artistName"] as? String ?? "",
                             title: item["name"] as? String ?? "",
                             url: url,
                             keyID: urls.compactMap { $0["encryptionKeyId"] as? String }.first ?? id,
                             imageURL: art.map { Self.trackArt + $0 } ?? "",
                             startOffset: (xtra["startOffset"] as? Double ?? 0) / 1000)
        }
        return (tracks, tune["sequenceToken"] as? String)
    }

    /// The track an Xtra channel would start with if tuned now, without downloading anything.
    func peek(channelID: String) async throws -> XtraTrack? {
        try await tune(channelID: channelID).tracks.first
    }

    // MARK: Live now playing

    /// What every live (non-Xtra) channel is playing right now, keyed by channel entity id, in one
    /// unauthenticated call: the "lookAround" feed the web player polls for its channel grid.
    /// Talk and sports channels fall back to the current show's art when the cut has none.
    /// Done the way the web player does it (its remote config: lookaround pollingMs 45000,
    /// livePointIntervalMs 60000): the feed is refetched at most every 45 s. The player runs at live
    /// (within 1 s), so the cut on air now is what a listener hears.
    func liveNowPlaying() async throws -> [String: NowPlaying] {
        if Date().timeIntervalSince(lookAroundFetched) > 45 {
            let (data, resp) = try await session.data(from: URL(string: Self.lookAround)!)
            if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 { throw XtraError.http(code, "lookAround") }
            lookAroundChannels = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["channels"] as? [String: [String: Any]] ?? [:]
            lookAroundFetched = Date()
        }
        let now = Date()
        var result = [String: NowPlaying]()
        for (id, ch) in lookAroundChannels {
            func current(_ key: String) -> [String: Any]? {
                (ch[key] as? [[String: Any]] ?? []).last { $0["isAd"] as? Bool != true && (Self.date($0["validFrom"] as? String) ?? now) <= now }
            }
            guard let cut = current("cuts") else { continue }
            let show = current("shows")
            let art = ((cut["image"] ?? show?["image"]) as? [String: Any])?["url"] as? String
            // Talk cuts have no artist; the web player shows the show's name in its place.
            let artist = cut["artistName"] as? String ?? ""
            result[id] = NowPlaying(artist: artist.isEmpty ? show?["name"] as? String ?? "" : artist,
                                    song: cut["name"] as? String ?? "",
                                    image: art.map { Self.imageURL(key: $0, size: 450) } ?? "")
        }
        return result
    }

    // MARK: Download

    /// Downloads and decrypts one track into a playable ADTS AAC file.
    func download(_ track: XtraTrack, into folder: URL) async throws -> URL {
        guard let masterURL = URL(string: track.url) else { throw XtraError.badResponse("track url") }
        let master = try await text(masterURL)
        let variants = master.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard let variant = variants.first(where: { $0.contains("_256k_") }) ?? variants.first,
              let variantURL = URL(string: variant, relativeTo: masterURL)?.absoluteURL
        else { throw XtraError.badResponse("no variant playlist") }

        var sequence = 0
        var iv: Data?
        var segments = [URL]()
        for line in try await text(variantURL).split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY"), let r = line.range(of: "IV=0x") {
                iv = Data(hex: String(line[r.upperBound...].prefix(32)))
            } else if !line.isEmpty, !line.hasPrefix("#"), let u = URL(string: line, relativeTo: variantURL)?.absoluteURL {
                segments.append(u)
            }
        }
        guard !segments.isEmpty else { throw XtraError.badResponse("empty playlist") }

        let keyJSON = try await json("GET", "/playback/key/v1/\(track.keyID)", body: nil, bearer: try await bearer())
        guard let keyB64 = keyJSON["key"] as? String, let key = Data(base64Encoded: keyB64), key.count == 16
        else { throw XtraError.badResponse("key") }

        let parts = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for (i, url) in segments.enumerated() {
                group.addTask {
                    let (data, resp) = try await self.session.data(from: url)
                    if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 { throw XtraError.http(code, "segment") }
                    // Without an explicit IV, HLS uses the segment's media sequence number.
                    let segIV = iv ?? Data(sequenceIV: sequence + i)
                    guard let plain = aes128Decrypt(data, key: key, iv: segIV) else { throw XtraError.badResponse("decrypt") }
                    return (i, stripID3(plain))
                }
            }
            var parts = [Int: Data]()
            for try await (i, data) in group { parts[i] = data }
            return parts
        }

        var audio = Data()
        for i in segments.indices { audio.append(parts[i]!) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(track.id).aac")
        try audio.write(to: file)
        return file
    }

    // MARK: HTTP

    private func text(_ url: URL) async throws -> String {
        let (data, resp) = try await session.data(from: url)
        if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 { throw XtraError.http(code, url.lastPathComponent) }
        return String(decoding: data, as: UTF8.self)
    }

    private func json(_ method: String, _ path: String, body: Any?, bearer: String?) async throws -> [String: Any] {
        guard let url = URL(string: path.hasPrefix("https://") ? path : Self.api + path) else { throw XtraError.badResponse(path) }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        req.httpMethod = method
        for (k, v) in ["Accept": "application/json; charset=utf-8", "Content-Type": "application/json; charset=UTF-8",
                       "Origin": "https://www.siriusxm.com", "Referer": "https://www.siriusxm.com/",
                       "User-Agent": Self.userAgent, "X-Sxm-Platform": "browser", "X-Sxm-Tenant": "sxm",
                       "X-Sxm-Clock": "[0,0]"] {
            req.setValue(v, forHTTPHeaderField: k)
        }
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body, options: .fragmentsAllowed) }

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code >= 400 { throw XtraError.http(code, url.path) }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: Decryption helpers

func aes128Decrypt(_ data: Data, key: Data, iv: Data) -> Data? {
    var out = Data(count: data.count + kCCBlockSizeAES128)
    var moved = 0
    let outCount = out.count
    let status = out.withUnsafeMutableBytes { o in
        data.withUnsafeBytes { d in
            key.withUnsafeBytes { k in
                iv.withUnsafeBytes { v in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, key.count, v.baseAddress, d.baseAddress, data.count,
                            o.baseAddress, outCount, &moved)
                }
            }
        }
    }
    guard status == kCCSuccess else { return nil }
    return out.prefix(moved)
}

/// Each HLS audio segment starts with an ID3 timestamp tag; drop it so the segments join into one clean AAC stream.
func stripID3(_ data: Data) -> Data {
    let b = [UInt8](data.prefix(10))
    guard b.count == 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return data }
    let size = Int(b[6] & 0x7f) << 21 | Int(b[7] & 0x7f) << 14 | Int(b[8] & 0x7f) << 7 | Int(b[9] & 0x7f)
    let header = 10 + size + (b[5] & 0x10 != 0 ? 10 : 0)
    return header < data.count ? data.subdata(in: data.startIndex + header ..< data.endIndex) : data
}

extension Data {
    init(sequenceIV n: Int) {
        var bytes = [UInt8](repeating: 0, count: 16)
        var v = UInt64(n)
        for i in (8..<16).reversed() { bytes[i] = UInt8(v & 0xff); v >>= 8 }
        self.init(bytes)
    }

    init?(hex: String) {
        guard hex.count == 32 else { return nil }
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        self.init(bytes)
    }
}
