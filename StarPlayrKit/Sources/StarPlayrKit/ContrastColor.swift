//
//  ContrastColor.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 10/31/26.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import SwiftUI

/// Picks bar colours that always stand out from the panel: WCAG relative luminance and
/// contrast ratio, lightening (dark mode) or darkening (light mode) a hue only as far as
/// needed to reach `minRatio`, so saturated colours survive wherever they already contrast.
public enum ContrastColor {
    /// Approximate luminance of the menu/panel material behind the bars.
    public static func background(_ scheme: ColorScheme) -> Double { scheme == .dark ? 0.025 : 0.84 }

    /// The contrast-checked colour as sRGB components (alpha 1), for the Metal shader.
    public static func components(hue: Double, saturation: Double, against bg: Double, minRatio: Double = 3.5) -> SIMD4<Float> {
        // Remembered per half-degree of hue: the same few hundred colours come round again and again,
        // and the search below costs up to 21 × 3 pow() calls.
        let key = Key(hue: Int((hue - floor(hue)) * 720), saturation: Int(saturation * 100),
                      bg: Int(bg * 1000), minRatio: Int(minRatio * 10))
        cacheLock.lock()
        let hit = cache[key]
        cacheLock.unlock()
        if let hit { return hit }
        let c = search(hue: Double(key.hue) / 720, saturation: saturation, against: bg, minRatio: minRatio)
        cacheLock.lock()
        if cache.count > 20_000 { cache.removeAll() }
        cache[key] = c
        cacheLock.unlock()
        return c
    }

    private struct Key: Hashable { let hue, saturation, bg, minRatio: Int }
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache = [Key: SIMD4<Float>]()

    private static func search(hue: Double, saturation: Double, against bg: Double, minRatio: Double) -> SIMD4<Float> {
        let dark = bg < 0.5
        // Dark background: full brightness, then wash toward white. Light: darken.
        for step in 0...20 {
            let k = Double(step) / 20
            let s = dark ? saturation * (1 - 0.7 * k) : saturation
            let b = dark ? 1 : 1 - 0.75 * k
            let (r, g, bl) = rgb(hue, s, b)
            let l = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(bl)
            let ratio = (max(l, bg) + 0.05) / (min(l, bg) + 0.05)
            if ratio >= minRatio || step == 20 { return [Float(r), Float(g), Float(bl), 1] }
        }
        return [1, 1, 1, 1]
    }

    /// Plain hue/saturation/brightness as sRGB components (alpha 1).
    public static func hsb(_ h: Double, _ s: Double, _ v: Double) -> SIMD4<Float> {
        let (r, g, b) = rgb(h, s, v)
        return [Float(r), Float(g), Float(b), 1]
    }

    private static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func rgb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let h6 = (h - floor(h)) * 6
        let f = h6 - floor(h6)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch Int(h6) % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}
