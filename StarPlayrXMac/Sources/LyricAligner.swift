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
//  Landing ON the line rather than near it is the whole point, so a line's score is not how loud
//  the curve is at its stamp — a bar stays loud for a second after the voice comes in, and the
//  highlight would sit anywhere in that second, a word or two out. It is how much LOUDER the
//  moment of the stamp is than the half-second before it: a rise happens at one instant, so the
//  best shift is pinned to that instant. The 0.1 s search then reads between its own steps off the
//  scores either side of the winner, which is worth another syllable.
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
    /// The window just after a line's stamp: "the voice is arriving about now". Narrow on purpose —
    /// it is what pins the moment down. Make it as wide as the lull below and the score stops being
    /// a peak and becomes a plateau as wide as the window, with the true arrival somewhere inside
    /// it, which is the word or two of slack this is here to remove. The slack a hand-typed LRC
    /// stamp needs comes from averaging two dozen lines, not from blurring each one.
    static let arrival = 0.12
    /// And the stretch before it that a line has to stand out from: the gap between phrases that
    /// the singer comes in out of. Wide enough to be a fair reading of "it was quieter than this".
    static let lull = 0.5
    /// The curve is jagged at 11 ms a frame. This much of each point's neighbours takes that jitter
    /// out without blunting the edge the arrival score is looking for.
    static let smoothing = 0.04

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
        // Running totals, so comparing a window either side of a stamp costs four lookups whatever
        // the window's width, instead of sixty adds per line per shift.
        var sums = [Double](repeating: 0, count: curve.count + 1)
        for i in 0..<curve.count { sums[i + 1] = sums[i] + Double(curve[i]) }
        let window = max(1, Int(arrival / onsets.step))
        let back = max(window + 1, Int(lull / onsets.step))

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
                guard index - back >= 0, index + window <= curve.count else { continue }
                // How much the music OPENS UP on the stamp, not how loud it is there: the moment
                // the line starts, against the lull it came out of. A busy bar scores nothing
                // unless the busyness ARRIVES on the stamp, which is what the start of a sung line
                // is. That is the difference between landing on the line and landing near it — the
                // level stays just as high for half a second after the voice comes in, and half a
                // second is the word or two the highlight was out by, while the rise is only at
                // the frame it actually happens.
                let before = (sums[index] - sums[index - back]) / Double(back)
                let after = (sums[index + window] - sums[index]) / Double(window)
                // Floored at nothing: a line that lands on a fade-out says nothing about the
                // shift, and mustn't pay for the lines that did land on a voice.
                total += max(0, after - before)
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
        guard scores.count > 2,
              let top = scores.indices.max(by: { scores[$0].score < scores[$1].score }) else { return nil }
        let best = scores[top]
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
        return Alignment(shift: refined(at: top, in: scores), confidence: confidence,
                         margin: margin, lines: best.lines)
    }

    /// The search walks in `step`s, so on its own the winner is only right to within half a step.
    /// The scores either side of it say where inside that step the peak really sits: three points
    /// fix a parabola, and its top is the answer. Half a step is a syllable, so it is worth having.
    static func refined(at top: Int, in scores: [(shift: Double, score: Double, lines: Int)]) -> Double {
        let shift = scores[top].shift
        // Only when the two neighbours really are one step either side — a shift whose lines fell
        // outside the audio isn't in `scores` at all, so next in the array can be seconds away.
        guard top > 0, top + 1 < scores.count,
              abs(scores[top - 1].shift - shift + step) < step / 2,
              abs(scores[top + 1].shift - shift - step) < step / 2 else { return shift }
        let (low, peak, high) = (scores[top - 1].score, scores[top].score, scores[top + 1].score)
        let curvature = low - 2 * peak + high
        guard curvature < 0 else { return shift }
        let delta = 0.5 * (low - high) / curvature
        return abs(delta) <= 0.5 ? shift + delta * step : shift
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
