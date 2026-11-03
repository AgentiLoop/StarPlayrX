//
//  LyricAligner.swift
//  StarPlayrXMac
//
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  Lines a song's lyrics up with the audio actually on air, instead of trusting the broadcast's
//  "this cut started now" stamp. The stamp is a few seconds out, and by a different few seconds on
//  every song (cross-fades, talk-ups, radio edits), so one constant can only ever be right for some
//  songs. This measures the shift from the sound itself.
//
//  How: the equalizer already turns every decoded segment into 16 band levels ~86 times a second.
//  Summing how much each band ROSE from one frame to the next gives an onset curve — singing
//  entering a quiet bar is a spike. A timestamped lyric is a list of moments when a line starts,
//  which is when those spikes happen. Slide the lyrics over the curve, and the shift that lands the
//  most line starts on the most onset is the one the station is really using.
//

import Foundation

enum LyricAligner {
    /// How far either way the search looks, and how finely.
    static let search: ClosedRange<Double> = -15...15
    static let step = 0.1
    /// Below this many lines inside the audio we have, the answer is noise. Six lines of a jingle
    /// will happily "match" something eleven seconds away.
    static let minimumLines = 12
    /// And those lines have to be spread over at least this much of the song, so a cluster inside
    /// one chorus can't decide where the whole thing sits.
    static let minimumSpan: Double = 60
    /// How far above the average score the winner has to stand (in standard deviations).
    static let minimumConfidence = 2.0
    /// How much better than the best *other* alignment the winner has to be. A song built on a
    /// repeated phrase ("doo doobie doo…") scores nearly as well a bar or a verse away, and that
    /// near-miss is what puts the highlight four lines out — so when the runner-up is close, the
    /// measurement is thrown away instead of believed.
    static let minimumMargin = 1.25
    /// Two peaks closer together than this are the same peak, not a rival.
    static let peakSpacing = 2.5
    /// A line's stamp and the moment it is actually sung are a few tenths apart (and LRC files are
    /// typed by hand), so each point on the curve carries this much of its neighbours.
    static let smoothing = 0.35

    struct Alignment: Equatable {
        /// Seconds to add to the position worked out from the cut's stamp.
        let shift: Double
        /// How far the winner stood above the field, in standard deviations.
        let confidence: Double
        /// How many times better than the best alignment well away from it.
        let margin: Double
        /// How many line starts were scored.
        let lines: Int
    }

    /// Takes the loudness out of it: a chorus is louder than a verse everywhere, which would let
    /// a wrong shift win just by landing lines in the loud half. What's left is how much each
    /// moment stands out from the half-minute around it.
    static func normalized(_ values: [Float]) -> [Float] {
        let background = smoothed(values, radius: 1_300)   // ~15 s either way at 86 frames a second
        guard background.count == values.count else { return values }
        // Divided, not subtracted: a spike in a quiet verse counts as much as one in a loud
        // chorus, and lines that come at a steady pace aren't mistaken for the background.
        let floor = max(1e-6, values.reduce(0, +) / Float(values.count) * 0.05)
        return zip(values, background).map { $0 / max($1, floor) }
    }

    /// `lineTimes` are seconds into the recording (the LRC stamps of lines that have words).
    /// `songStart` is where the broadcast says the cut began, `onsets` the curve from
    /// `SpectrumTimeline.onsets(channel:)`. Nil when there isn't enough to be sure.
    static func align(lineTimes: [Double], songStart: Date,
                      onsets: (start: Date, step: Double, values: [Float])) -> Alignment? {
        guard onsets.step > 0, !onsets.values.isEmpty, !lineTimes.isEmpty else { return nil }
        // Where each line falls on the onset curve when nothing is shifted, in frames.
        let offset = songStart.timeIntervalSince(onsets.start) / onsets.step
        let frames = lineTimes.map { offset + $0 / onsets.step }
        let curve = normalized(smoothed(onsets.values, radius: Int(smoothing / onsets.step)))

        var scores = [(shift: Double, score: Double, lines: Int)]()
        var shift = search.lowerBound
        while shift <= search.upperBound {
            let delta = shift / onsets.step
            var total = 0.0
            var counted = 0
            var first = Double.infinity
            var last = -Double.infinity
            for (i, frame) in frames.enumerated() {
                let index = Int((frame + delta).rounded())
                guard index >= 0, index < curve.count else { continue }
                total += Double(curve[index])
                counted += 1
                first = min(first, lineTimes[i])
                last = max(last, lineTimes[i])
            }
            // An average, not a sum: a shift that happens to drag more lines into the window
            // mustn't win on count alone.
            if counted >= minimumLines, last - first >= minimumSpan {
                scores.append((shift, total / Double(counted), counted))
            }
            shift += step
        }
        guard scores.count > 2, let best = scores.max(by: { $0.score < $1.score }) else { return nil }
        let values = scores.map(\.score)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let deviation = variance.squareRoot()
        guard deviation > 0, best.score > 0 else { return nil }
        let confidence = (best.score - mean) / deviation
        // The best alignment that isn't just a neighbour of the winner.
        let rival = scores.filter { abs($0.shift - best.shift) >= peakSpacing }.map(\.score).max() ?? 0
        let margin = rival > 0 ? best.score / rival : .infinity
        guard confidence >= minimumConfidence, margin >= minimumMargin else { return nil }
        return Alignment(shift: best.shift, confidence: confidence, margin: margin, lines: best.lines)
    }

    /// A singer doesn't land on the exact millisecond of the stamp, and the curve is jagged at
    /// 11 ms a frame, so each point carries a little of its neighbours.
    static func smoothed(_ values: [Float], radius: Int = 5) -> [Float] {
        guard radius > 0, values.count > radius * 2 else { return values }
        var out = [Float](repeating: 0, count: values.count)
        var window: Float = 0
        for i in 0..<values.count {
            window += values[i]
            if i >= radius * 2 + 1 { window -= values[i - radius * 2 - 1] }
            let centre = i - radius
            if centre >= 0 { out[centre] = window / Float(min(i + 1, radius * 2 + 1)) }
        }
        // The last `radius` points never became a centre; leave them as they were.
        for i in max(0, values.count - radius)..<values.count { out[i] = values[i] }
        return out
    }
}
