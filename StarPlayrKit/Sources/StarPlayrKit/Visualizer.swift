//
//  Visualizer.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 10/31/26.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import Foundation
import QuartzCore

/// Simulation runs independently of AppKit's tracking loop. Only value snapshots cross queues.
public final class Visualizer: @unchecked Sendable {
    public static let shared = Visualizer()
    public static let bandCount = 24
    public struct Frame {
        public var levels: [Float], hues: [Double], rise: [Double], history: [[Float]]
        public var previous: (levels: [Float], rise: [Double], pulse: Double, blobX: Double)
        public var phase: Double, pulse: Double, blobX: Double
        public var generation: Int
        public var time: CFTimeInterval
        public var playing: Bool

        public func fraction(now: CFTimeInterval) -> Float {
            playing ? Float(min(1, max(0, (now - time) / SpectrumSimulation.step))) : 1
        }
    }
    private let queue = DispatchQueue(label: "com.starplayrx.eq", qos: .userInteractive)
    private let lock = NSLock()
    private let simulation = SpectrumSimulation()
    private var cached: Frame
    private var timer: DispatchSourceTimer?
    public var frame: Frame { lock.lock(); defer { lock.unlock() }; return cached }

    private init() { cached = simulation.frame }

    public func start() {
        queue.async {
            self.simulation.start()
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: SpectrumSimulation.step, leeway: .milliseconds(1))
            timer.setEventHandler { self.advance() }
            self.timer = timer
            timer.resume()
        }
    }

    public func stop() {
        queue.async {
            self.simulation.stop()
            if !self.simulation.running { self.timer?.cancel(); self.timer = nil }
            self.publish()
        }
    }

    private func advance() {
        dispatchPrecondition(condition: .onQueue(queue))
        simulation.tick(now: CACurrentMediaTime())
        publish()
    }

    private func publish() {
        let value = simulation.frame
        lock.lock(); cached = value; lock.unlock()
    }

}

/// Mutable state is confined to Visualizer's serial simulation queue.
private final class SpectrumSimulation {
    private static let bandCount = Visualizer.bandCount
    /// Seconds between state steps. Each step runs the 60 fps tuned update twice, so speeds are unchanged.
    static let step = 1.0 / 30

    private(set) var levels = [Float](repeating: 0, count: bandCount)
    /// Lava-lamp colour phase (in hue turns). Drifts slowly and speeds up with loudness.
    private(set) var phase: Double = 0
    /// Bass kick above its recent average, 0...1: drives the glow and blob pulse.
    private(set) var pulse: Double = 0
    /// Background blob position, -1 (left) ... 1 (right): follows where the music's energy
    /// sits in the spectrum plus a random wander that jumps on beats.
    private(set) var blobX: Double = 0
    /// Per-bar hue (0...1 turns), driven by the music; see `update`.
    private(set) var hues = (0..<bandCount).map { _ in Double.random(in: 0..<1) }
    /// Lava-lamp bubbles inside each bar: how far they have risen (in bar heights, wraps at 1).
    /// They drift up slowly when the band is quiet and faster when it's loud; a kick gives them a push.
    private(set) var rise = (0..<bandCount).map { _ in Double.random(in: 0..<1) }
    /// The state one step back, for tweening: levels, rise, pulse, blob position.
    private(set) var previous = (levels: [Float](repeating: 0, count: bandCount), rise: [Double](repeating: 0, count: bandCount), pulse: 0.0, blobX: 0.0)
    /// Bar heights of the last four steps, oldest first, for the shader's curve.
    private(set) var history = [[Float]](repeating: [Float](repeating: 0, count: bandCount), count: 4)
    /// Bumped on every step, so each renderer knows when to rebuild its bar colours.
    private(set) var generation = 0
    private var hueTargets = (0..<bandCount).map { _ in Double.random(in: 0..<1) }
    private var paletteCooldown = 0
    private var bassAverage: Float = 0
    private var wander: Double = 0
    private var wanderTarget: Double = 0

    private(set) var running = false
    private var lastStep: CFTimeInterval = 0
    private var viewers = 0   // menu and torn-off window can both show bars
    private var playing = false
    var frame: Visualizer.Frame {
        .init(levels: levels, hues: hues, rise: rise, history: history, previous: previous,
              phase: phase, pulse: pulse, blobX: blobX, generation: generation, time: lastStep, playing: playing)
    }

    func start() {
        viewers += 1
        running = true
    }

    func stop() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        running = false
        levels = [Float](repeating: 0, count: Self.bandCount)
        pulse = 0
        previous = (levels, rise, 0, blobX)
        history = [[Float]](repeating: levels, count: 4)
        generation &+= 1
    }

    func tick(now: CFTimeInterval) {
        // Paused: freeze the frame (bars, bubbles and colours) where the music stopped.
        let playback = PlaybackWorker.shared.snapshot
        playing = playback.isXtra ? playback.xtraStatus != .paused : playback.liveStatus != .paused
        guard playing else { lastStep = now; return }
        if running, now - lastStep >= Self.step - 0.004 {
            previous = (levels, rise, pulse, blobX)
            history.removeFirst()
            // The shader draws a smooth curve through the last four steps, which shows each one two
            // steps (~67 ms) late; reading the audio two steps ahead puts the bars back on the beat.
            // A step spans ~3 analysis frames (11.6 ms each); reading just one picked a random frame and
            // the bars twitched. Average the three, and read a little further ahead for the softer easing below.
            let reads = [0.0, 1.0 / 3, 2.0 / 3].compactMap { playback.spectrum(ahead: (2 + $0) * Self.step + 0.04) }
            let new = reads.isEmpty ? [Float](repeating: 0, count: Self.bandCount)
                : (0..<Self.bandCount).map { i in reads.reduce(0) { $0 + $1[i] } / Float(reads.count) }
            update(new)
            update(new)
            history.append(levels)
            // Keep to the 30 Hz grid, but don't try to catch up after a pause.
            lastStep = now - lastStep < 2 * Self.step ? lastStep + Self.step : now
            generation &+= 1
        }
    }

    private func update(_ new: [Float]) {
        guard running else { return }
        let previous = levels
        // Rise fast but over a few frames, fall slowly. At 60 fps an instant rise showed every
        // frame-to-frame wobble of the FFT as jitter; easing in hides it without adding lag you can see.
        // Softer than before (0.55 up, ×0.894 down): bars ease toward each new height instead of jumping.
        levels = zip(levels, new).map { old, new in new > old ? old + (new - old) * 0.35 : max(new, old - (old - new) * 0.18) }
        rise = rise.indices.map { i in
            (rise[i] + 0.0015 + 0.006 * Double(levels[i]) + 0.004 * pulse).truncatingRemainder(dividingBy: 1)
        }
        // 60 updates a second (every step below is half its 30 fps size): quiet ≈ one colour cycle per 30 s, loud ≈ one per 3 s.
        let energy = Double(new.reduce(0, +) / Float(new.count))
        phase = (phase + 0.0005 + energy * 0.01).truncatingRemainder(dividingBy: 1)
        let bass = new.prefix(4).reduce(0, +) / 4
        let kick = bass - bassAverage
        bassAverage = bassAverage * 0.975 + bass * 0.025
        pulse = max(Double(max(0, kick) * 4).clamped, pulse * 0.922)

        // Bar colours blend the old rolling wave (global phase plus a slow wave across the bars)
        // halfway toward a random palette. A strong kick (at most every ~3 s) or a rare random
        // moment throws a new palette; each bar glides there at a pace set by its own band,
        // onsets nudge it, and each bar is softened toward its neighbours so colours flow sideways.
        paletteCooldown -= 1
        if (kick > 0.25 && paletteCooldown <= 0) || Int.random(in: 0..<900) == 0 {
            newPalette()
            paletteCooldown = 180
        }
        let t = phase * 2 * .pi
        let glided = hues.indices.map { i in
            let x = Double(i) / Double(Self.bandCount)
            let wave = phase + x * 0.3 + 0.08 * sin(x * 7 + t * 3)
            let target = wave + 0.5 * Self.shortest(hueTargets[i] - wave)
            let level = Double(new[i])
            let onset = Double(max(0, new[i] - previous[i]))
            return hues[i] + Self.shortest(target - hues[i]) * (0.005 + 0.04 * level) + onset * 0.02
        }
        hues = glided.indices.map { i in
            let left = glided[max(0, i - 1)], right = glided[min(glided.count - 1, i + 1)]
            let h = glided[i] + 0.125 * (Self.shortest(left - glided[i]) + Self.shortest(right - glided[i]))
            return (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
        }

        // Spectral centroid, 0 (bass-heavy) ... 1 (treble-heavy).
        let total = new.reduce(0, +)
        let weighted = new.enumerated().reduce(Float(0)) { $0 + Float($1.offset) * $1.element }
        let centroid = total > 0.01 ? Double(weighted / total) / Double(new.count - 1) : 0.5
        // New random spot on a strong kick, or now and then on its own.
        if kick > 0.15 || Int.random(in: 0..<180) == 0 { wanderTarget = .random(in: -1...1) }
        wander += (wanderTarget - wander) * 0.02
        let target = Swift.min(1, Swift.max(-1, (centroid * 2 - 1) * 1.5 + wander * 0.6))
        blobX += (target - blobX) * 0.04
    }

    /// Hue difference taken the shortest way round the colour wheel, -0.5...0.5.
    private static func shortest(_ d: Double) -> Double {
        var d = d.truncatingRemainder(dividingBy: 1)
        if d > 0.5 { d -= 1 } else if d < -0.5 { d += 1 }
        return d
    }

    /// Random palette in a random scheme, so the row never settles into one predictable cycle.
    private func newPalette() {
        let base = Double.random(in: 0..<1)
        let scheme = Int.random(in: 0..<5)
        let n = Self.bandCount
        hueTargets = (0..<n).map { i in
            let jitter = Double.random(in: -0.04...0.04)
            switch scheme {
            case 0: return base + jitter                                          // analogous
            case 1: return base + (Bool.random() ? 0 : 0.5) + jitter              // complementary
            case 2: return base + Double(Int.random(in: 0..<3)) / 3 + jitter      // triad
            case 3: return base + Double(i) / Double(n) * .random(in: 0.3...1)    // sweep
            default: return .random(in: 0..<1)                                    // confetti
            }
        }
    }
}
