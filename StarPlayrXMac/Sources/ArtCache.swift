//
//  ArtCache.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 10/31/26.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import SwiftUI
import ImageIO

/// Channel art scaled to fit; when the art is square (it would fit the squircle but leave a margin
/// and show its own baked-in corners) it's enlarged to fill the squircle instead — but only as far
/// as the art's own blank margin allows, so a show logo whose lettering runs close to the edge
/// ("The Rich Eisen Show") keeps its wording instead of being cropped into.
struct ChannelLogo: View {
    let image: NSImage
    var inset: CGFloat = 4

    var body: some View {
        let isSquare = abs(image.size.width - image.size.height) < 2
        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            .scaleEffect(isSquare ? Self.fillScale(image) : 1)
            .padding(isSquare ? 0 : inset)
    }
}

extension ChannelLogo {
    /// Most the art is enlarged, even when it is blank all around: covers the corner a logo of its
    /// own rounded tile leaves behind.
    static let maxFill: CGFloat = 1.12
    /// Scanning the bitmap costs more than a row's body may spend, and the same art is shown in
    /// every row refresh; `ArtCache` hands back the same `NSImage` each time, so key on it.
    @MainActor private static var fillScales: [ObjectIdentifier: CGFloat] = [:]

    @MainActor static func fillScale(_ image: NSImage) -> CGFloat {
        if let scale = fillScales[ObjectIdentifier(image)] { return scale }
        let margin = blankMargin(image)
        // scaleEffect shows 1/s of the art, centred, so each side loses (1 - 1/s)/2.
        let scale = margin < 0.01 ? 1 : min(maxFill, 1 / (1 - 2 * margin))
        if fillScales.count > 400 { fillScales.removeAll() }   // art evicted from the cache never comes back here
        fillScales[ObjectIdentifier(image)] = scale
        return scale
    }

    /// The blank band around the art — transparent, or the flat colour its edges are — as a
    /// fraction of the art, taken from its tightest side. 0 when the artwork reaches an edge.
    nonisolated private static func blankMargin(_ image: NSImage) -> CGFloat {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        let w = cg.width, h = cg.height
        guard w >= 16, h >= 16,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))   // memory row 0 is the top row
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        typealias Pixel = (r: Int, g: Int, b: Int, a: Int)
        func pixel(_ x: Int, _ y: Int) -> Pixel {
            let i = (y * w + x) * 4
            return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]), Int(px[i + 3]))
        }
        // The background: the middle of the top edge, which a rounded logo tile has even where its
        // corners are cut away. Nothing there but transparency means the art is only transparent.
        let top = pixel(w / 2, 0)
        let background: Pixel? = top.a > 16 ? top : nil
        func isBlank(_ p: Pixel) -> Bool {
            if p.a <= 16 { return true }
            guard let bg = background else { return false }
            return abs(p.r - bg.r) <= 12 && abs(p.g - bg.g) <= 12 && abs(p.b - bg.b) <= 12 && abs(p.a - bg.a) <= 12
        }
        // Read over the middle of each line only, so a rounded corner doesn't decide the edge.
        let xs = stride(from: w / 10, to: w - w / 10, by: 1), ys = stride(from: h / 10, to: h - h / 10, by: 1)
        func depth(upTo limit: Int, _ line: (Int) -> Bool) -> Int {
            var n = 0
            while n < limit, line(n) { n += 1 }
            return n
        }
        // Only the first 15% matters: filling the squircle never needs more than maxFill.
        let limitY = h * 3 / 20, limitX = w * 3 / 20
        let t = depth(upTo: limitY) { y in xs.allSatisfy { isBlank(pixel($0, y)) } }
        let b = depth(upTo: limitY) { y in xs.allSatisfy { isBlank(pixel($0, h - 1 - y)) } }
        let l = depth(upTo: limitX) { x in ys.allSatisfy { isBlank(pixel(x, $0)) } }
        let r = depth(upTo: limitX) { x in ys.allSatisfy { isBlank(pixel(w - 1 - x, $0)) } }
        return min(CGFloat(min(t, b)) / CGFloat(h), CGFloat(min(l, r)) / CGFloat(w))
    }
}


/// Channel logos and album art kept in memory once loaded. Nothing is fetched until it's shown or about to be (list look-ahead),
/// and a URL that is already loading is shared instead of downloaded twice. Each image is fetched
/// (where the server can resize) and decoded at 2x the points it is shown at, so the 32pt channel
/// rows and the 64pt Now Playing tile each get their own size, and the cache is bounded.
@MainActor
final class ArtCache {
    static let shared = ArtCache()
    private let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        cache.totalCostLimit = 200 * 192 * 192 * 4
        return cache
    }()
    /// Its own on-disk URL cache (small in memory), so art evicted from `images` or from a
    /// previous launch comes back from disk instead of the network.
    nonisolated private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 2 * 1024 * 1024, diskCapacity: 100 * 1024 * 1024,
                                   directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                                       .appendingPathComponent(Bundle.main.bundleIdentifier ?? "StarPlayrX", isDirectory: true)
                                       .appendingPathComponent("ArtCache", isDirectory: true))
        config.requestCachePolicy = .returnCacheDataElseLoad   // art at a URL never changes
        return URLSession(configuration: config)
    }()
    // Download and decode run off the main actor so arriving art never stalls scrolling;
    // the NSImage is made here on the main actor, since NSImage is only Sendable from macOS 14.
    private var loading: [String: Task<Thumbnail?, Never>] = [:]
    /// `sized(_:pixels:)` results: it base64-decodes JSON, too slow to redo in every row's body.
    private var sizedURLs: [String: String] = [:]

    /// A decoded bitmap handed back from a background task.
    struct Thumbnail: @unchecked Sendable { let image: CGImage }

    /// Pixels for art shown at `points`: 3x, so square logos enlarged 1.12x to fill the squircle
    /// are still downscaled on a 2x display instead of stretched (which made them blurry).
    static let scale: CGFloat = 3
    static func pixels(_ points: CGFloat) -> Int { Int((points * scale).rounded(.up)) }

    // Keyed by pixels too: hosts with one size give the 32pt row and the 64pt header the same URL,
    // and the header must not get the row's small bitmap.
    func cached(_ url: String, pixels: Int) -> NSImage? {
        images.object(forKey: "\(pixels) \(sizedURL(url, pixels: pixels))" as NSString)
    }

    /// `trimBorder` (album art): a solid frame around the picture is cropped off, see `trimmedBorder`.
    func image(_ url: String, pixels: Int, trimBorder: Bool = false) async -> NSImage? {
        let url = sizedURL(url, pixels: pixels)
        let key = "\(pixels) \(url)"
        if let image = images.object(forKey: key as NSString) { return image }
        guard !url.isEmpty, let address = URL(string: url) else { return nil }
        // Big art (Now Playing full size) is waited on by the user; list thumbnails can trail behind.
        let task = loading[key] ?? Task.detached(priority: pixels > 300 ? .userInitiated : .utility) {
            guard let data = try? await ArtCache.session.data(from: address).0,
                  let thumb = ArtCache.thumbnail(data, pixels: pixels, trimBorder: trimBorder) else { return nil }
            return Thumbnail(image: thumb)
        }
        loading[key] = task
        let thumb = await task.value?.image
        loading[key] = nil
        if let image = images.object(forKey: key as NSString) { return image }   // another caller already made it
        guard let thumb else { return nil }
        let image = NSImage(cgImage: thumb, size: NSSize(width: CGFloat(thumb.width) / Self.scale, height: CGFloat(thumb.height) / Self.scale))
        images.setObject(image, forKey: key as NSString, cost: thumb.bytesPerRow * thumb.height)
        return image
    }

    /// Starts loading art that isn't shown yet; `image` shares the download if a row asks for it meanwhile.
    func prefetch(_ url: String, pixels: Int, trimBorder: Bool = false) {
        guard !url.isEmpty, cached(url, pixels: pixels) == nil else { return }
        Task { _ = await image(url, pixels: pixels, trimBorder: trimBorder) }
    }

    private func sizedURL(_ url: String, pixels: Int) -> String {
        let key = "\(pixels) \(url)"
        if let sized = sizedURLs[key] { return sized }
        let sized = Self.sized(url, pixels: pixels)
        sizedURLs[key] = sized
        return sized
    }

    /// The same art at the smallest size the server offers that still covers `pixels`.
    /// Other hosts (live channel logos, Xtra track art) only have one size and are just decoded smaller.
    private static func sized(_ url: String, pixels: Int) -> String {
        // SiriusXM's image server (channel tiles): the resize is part of the base64 JSON path.
        let imageServer = "https://imgsrv-sxm-prod-device.streaming.siriusxm.com/"
        if url.hasPrefix(imageServer),
           let data = Data(base64Encoded: String(url.dropFirst(imageServer.count))),
           var spec = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            spec["edits"] = [["resize": ["width": pixels, "height": pixels]]]
            guard let json = try? JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys, .withoutEscapingSlashes])
            else { return url }
            return imageServer + json.base64EncodedString()
        }
        // Live album art comes as _m (450px); _t is 75px and _s 170px.
        if url.hasPrefix("http://albumart.siriusxm.com/"), url.hasSuffix("_m.jpg") {
            let size = pixels <= 75 ? "_t" : pixels <= 170 ? "_s" : "_m"
            return url.dropLast("_m.jpg".count) + size + ".jpg"
        }
        return url
    }

    /// Decodes straight to a small bitmap, so neither the downloaded Data nor a full-size image is kept.
    nonisolated private static func thumbnail(_ data: Data, pixels: Int, trimBorder: Bool) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: pixels]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return trimBorder ? trimmedBorder(thumb) : thumb
    }

    /// Some album art is boxed in a solid frame (a white or black margin, or non-square art
    /// letterboxed to a square), and filling the squircle with it shows the frame instead of the
    /// picture. Scans in from each edge for rows/columns of one colour and crops them off, so
    /// `scaledToFill` zooms to the picture. Only a frame is cropped: the two sides of a pair
    /// (top/bottom, left/right) must be the same colour and about as deep, and end well inside
    /// the picture — a cover with a flat sky, or a flat background all the way to the middle, is
    /// not a frame and is left alone.
    nonisolated private static func trimmedBorder(_ image: CGImage) -> CGImage {
        let w = image.width, h = image.height
        guard w >= 16, h >= 16,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))   // memory row 0 is the top row
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        typealias RGB = (Int, Int, Int)
        func pixel(_ x: Int, _ y: Int) -> RGB {
            let i = (y * w + x) * 4
            return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
        }
        // JPEG ringing and dithering within a flat colour; opposite sides of a frame drift further.
        func near(_ a: RGB, _ b: RGB, tolerance: Int = 28) -> Bool {
            abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance
        }
        // How deep the frame is on one side: lines (rows or columns) from the edge inward, and the
        // colour of the outermost line. A frame is a band of one flat colour, which may carry a
        // title or logo (a sliver of other pixels, or a bold title with the band's colour back
        // after it) and may be followed by a thin band of another flat colour (double border,
        // hairline). It ends at a line that is mostly another colour: the picture's edge. Depth 0
        // when it isn't a frame: the band gave way gradually (a horse against a flat background of
        // the same colour); `limit` when it never ended (a flat background all the way in).
        func inset(upTo limit: Int, _ line: (Int) -> [RGB]) -> (depth: Int, color: RGB) {
            let count = line(0).count
            let allowed = count / 100        // stray pixels a flat line may have
            let thin = max(3, count / 12)    // an inner band deeper than this is the picture, not a border
            func mean(_ l: [RGB]) -> RGB {
                (l.map(\.0).reduce(0, +) / count, l.map(\.1).reduce(0, +) / count, l.map(\.2).reduce(0, +) / count)
            }
            func off(_ l: [RGB], _ c: RGB) -> Int { l.filter { !near($0, c) }.count }
            let outer = mean(line(0))
            var ref = outer          // colour of the band being scanned
            var bandStart = 0        // where that band began
            var lastFlat = -1        // last line that was flat in `ref`
            var edge: Int?           // the band ended here, on a line mostly another colour
            var n = 0
            while n < limit {
                let l = line(n), m = mean(l)
                let flat = off(l, m) <= allowed
                if let e = edge {
                    // Just past the band: a flat line of another colour within 2 lines (JPEG blurs
                    // the transition) is an inner border; the band's own colour again within 2
                    // thins means a title or hairline sat in the band. Otherwise the picture
                    // starts at the edge.
                    if flat, near(m, ref) {
                        edge = nil
                        lastFlat = n
                    } else if flat, n - e <= 2 {
                        ref = m; bandStart = e
                        edge = nil
                        lastFlat = n
                    } else if n - e >= 2 * thin {
                        return (e, outer)
                    }
                } else if bandStart > 0, n - bandStart > thin {
                    return (bandStart, outer)   // an inner band this deep is the picture (a flat sky)
                } else if flat, near(m, ref) {
                    lastFlat = n
                } else if off(l, ref) * 2 >= count {
                    // Gave way gradually: a subject against a flat background, not a frame. Inside
                    // an inner band that means the band was the picture.
                    if n - lastFlat > 3 { return (bandStart, outer) }
                    edge = n
                }
                n += 1
            }
            if let e = edge { return (e, outer) }
            return (bandStart > 0 ? bandStart : limit, outer)
        }
        // A pair of opposite sides is a frame when both are bands of the same colour that reached
        // the picture and are about as deep. On its own (a letterbox) the pair is nearly symmetric;
        // when all four sides are bands of one colour it is a full frame, and the side carrying the
        // title may be a good deal deeper. Each side loses its depth plus one line, where the
        // frame's edge bleeds into the picture.
        typealias Side = (depth: Int, color: RGB)
        func band(_ a: Side, _ b: Side, limit: Int) -> Bool {
            a.depth > 0 && b.depth > 0 && a.depth < limit && b.depth < limit && near(a.color, b.color, tolerance: 40)
        }
        func symmetric(_ a: Side, _ b: Side, within slack: Int) -> Bool { abs(a.depth - b.depth) <= max(3, slack) }
        // Letterboxed 2.35:1 art has bars of 29% a side, so look up to 30% in. Each line is read
        // over the middle 70% of its length only, so the frame along the other two sides (and a
        // hairline inside it) doesn't make the lines of an inner band look busy.
        let limitY = h * 3 / 10, limitX = w * 3 / 10
        let xs = (w * 3 / 20)..<(w * 17 / 20), ys = (h * 3 / 20)..<(h * 17 / 20)
        let t = inset(upTo: limitY) { y in xs.map { pixel($0, y) } }
        let b = inset(upTo: limitY) { y in xs.map { pixel($0, h - 1 - y) } }
        let l = inset(upTo: limitX) { x in ys.map { pixel(x, $0) } }
        let r = inset(upTo: limitX) { x in ys.map { pixel(w - 1 - x, $0) } }
        let rows = band(t, b, limit: limitY), cols = band(l, r, limit: limitX)
        let full = rows && cols && near(t.color, l.color, tolerance: 40)
            && symmetric(t, b, within: limitY / 3) && symmetric(l, r, within: limitX / 3)
        let (top, bottom) = full || (rows && symmetric(t, b, within: limitY / 5)) ? (t.depth + 1, b.depth + 1) : (0, 0)
        let (left, right) = full || (cols && symmetric(l, r, within: limitX / 5)) ? (l.depth + 1, r.depth + 1) : (0, 0)
        guard top + bottom + left + right > 0 else { return image }
        let rect = CGRect(x: left, y: top, width: w - left - right, height: h - top - bottom)
        return image.cropping(to: rect) ?? image
    }
}

/// Shows the image at `url` from `ArtCache`, loading it lazily at 2x `size` points. `content` gets
/// the image and whether it is album art (`isAlbumArt` belongs to `url`); nil when nothing is loaded.
struct CachedArt<Content: View>: View {
    let url: String
    let size: CGFloat
    var isAlbumArt = false
    @ViewBuilder let content: (NSImage?, Bool) -> Content
    @State private var loaded: (url: String, image: NSImage?, isAlbumArt: Bool)?

    var body: some View {
        let pixels = ArtCache.pixels(size)
        let image = loaded?.url == url ? loaded?.image : ArtCache.shared.cached(url, pixels: pixels)
        // Until the new art arrives, keep showing the previous art as it was (album art stays album
        // art): no flash of the logo or the StarPlayrX icon in between, in the header or in a row.
        Group {
            if let image { content(image, isAlbumArt) } else { content(loaded?.image, loaded?.isAlbumArt ?? false) }
        }
        .task(id: url) {
            let image = await ArtCache.shared.image(url, pixels: pixels, trimBorder: isAlbumArt)
            if !Task.isCancelled { loaded = (url, image, isAlbumArt) }
        }
    }
}
