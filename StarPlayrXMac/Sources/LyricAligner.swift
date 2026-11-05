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
    /// 1.5 rather than a stricter gate: a song whose lines land on the curve a little less
    /// cleanly (a busy mix, a fast rap) still gets its measured shift, which is what keeps the
    /// highlight on the line instead of falling back to a constant that is wrong for this song.
    static let minimumConfidence = 1.5
    /// How much better than the best *other* alignment the winner has to be. A song built on a
    /// repeated phrase ("doo doobie doo…") scores nearly as well a bar or a verse away, and that
    /// near-miss is what puts the highlight four lines out — so when the runner-up is close, the
    /// measurement is thrown away instead of believed. 1.15 still throws away those near-misses
    /// while letting a chorus that echoes itself through.
    static let minimumMargin = 1.15
    /// Two peaks closer together than this are the same peak, not a rival.
    static let peakSpacing = 2.5
    /// When the words we were given are not the same CUT of the record as the one on air, they are
    /// out by far more than the search above allows for. LRCLIB keeps "Wild Wild West (Album
    /// Version With Intro)" — a spoken intro the radio edit hasn't got — and every line of it is
    /// stamped twenty-four seconds late, so the ordinary search is only ever looking at the wrong
    /// half-minute and comes back with nothing. Looking this wide every time would turn up a rival
    /// peak on most songs, and the margin test would then refuse songs it corrects today, so the
    /// wide look is only taken when the ordinary one found nothing at all — and it has to pass the
    /// same gates, so a whole verse of a shift is only believed on the same evidence as a second.
    static let wideSearch: ClosedRange<Double> = -35...35
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

    /// The onset curve with its running totals staged for `arrivalScore`: where each line falls
    /// on the curve in frames when nothing is shifted, the normalized curve, and prefix sums, so
    /// comparing a window either side of a stamp costs four lookups whatever the window's width,
    /// instead of sixty adds per line per shift.
    private static func prepared(lineTimes: [Double], songStart: Date,
                                 onsets: (start: Date, step: Double, values: [Float]))
    -> (frames: [Double], curve: [Float], sums: [Double], step: Double)? {
        guard onsets.step > 0, !onsets.values.isEmpty, !lineTimes.isEmpty else { return nil }
        let offset = songStart.timeIntervalSince(onsets.start) / onsets.step
        let frames = lineTimes.map { offset + $0 / onsets.step }
        let curve = normalized(smoothed(onsets.values, radius: Int(smoothing / onsets.step)))
        var sums = [Double](repeating: 0, count: curve.count + 1)
        for i in 0..<curve.count { sums[i + 1] = sums[i] + Double(curve[i]) }
        return (frames, curve, sums, onsets.step)
    }

    /// The mean arrival score of one shift, and how many lines it counted: how much the music
    /// OPENS UP on each line's stamp, not how loud it is there — the moment the line starts,
    /// against the lull it came out of. A busy bar scores nothing unless the busyness ARRIVES on
    /// the stamp, which is what the start of a sung line is. That is the difference between
    /// landing on the line and landing near it: the level stays just as high for half a second
    /// after the voice comes in, and half a second is the word or two the highlight was out by,
    /// while the rise is only at the frame it actually happens. An average, not a sum, so a shift
    /// that drags more lines into the window doesn't win on count alone. Each line's contribution
    /// is floored at nothing: a line that lands on a fade-out says nothing and mustn't pay for the
    /// lines that did land on a voice. Nil when too few lines fall inside the audio to say
    /// anything about this shift.
    private static func arrivalScore(_ shift: Double, frames: [Double], lineTimes: [Double],
                                     curve: [Float], sums: [Double], step: Double) -> (score: Double, lines: Int, span: Double)? {
        let delta = shift / step
        let window = max(1, Int(arrival / step))
        let back = max(window + 1, Int(lull / step))
        var total = 0.0
        var counted = 0
        var first = Double.infinity
        var last = -Double.infinity
        for (i, frame) in frames.enumerated() {
            let index = Int((frame + delta).rounded())
            guard index - back >= 0, index + window <= curve.count else { continue }
            let before = (sums[index] - sums[index - back]) / Double(back)
            let after = (sums[index + window] - sums[index]) / Double(window)
            total += max(0, after - before)
            counted += 1
            first = min(first, lineTimes[i])
            last = max(last, lineTimes[i])
        }
        guard counted >= minimumLines, last - first >= minimumSpan else { return nil }
        return (total / Double(counted), counted, last - first)
    }

    /// The score one shift gets on this audio. `align` scores a whole range of shifts this way;
    /// a lock already held is checked against fresh audio by scoring it alone, so the two are
    /// compared on the SAME audio. Nil when too few lines fall inside to say anything.
    static func score(of shift: Double, lineTimes: [Double], songStart: Date,
                      onsets: (start: Date, step: Double, values: [Float])) -> Double? {
        guard let p = prepared(lineTimes: lineTimes, songStart: songStart, onsets: onsets) else { return nil }
        return arrivalScore(shift, frames: p.frames, lineTimes: lineTimes, curve: p.curve, sums: p.sums, step: p.step)?.score
    }

    /// Which of two locks to keep. A candidate within `agree` of the held one is a refinement of
    /// it and always wins; one further away is a rival peak (a chorus echoing a verse, a line
    /// away), and the two confidences were earned on different amounts of audio, so comparing
    /// them says nothing — both shifts are re-scored on the audio the candidate was just
    /// measured on, and the one that fits THAT better is the lock. That is what lets a highlight
    /// parked a line out correct itself once enough audio has come in to tell the lines apart.
    static func choose(held: Alignment, heldShift: Double, candidate: Alignment,
                       lineTimes: [Double], songStart: Date,
                       onsets: (start: Date, step: Double, values: [Float]), agree: Double) -> Alignment {
        guard abs(candidate.shift - heldShift) > agree else { return candidate }
        let heldScore = score(of: heldShift, lineTimes: lineTimes, songStart: songStart, onsets: onsets)
        let candidateScore = score(of: candidate.shift, lineTimes: lineTimes, songStart: songStart, onsets: onsets)
        if let h = heldScore, let c = candidateScore, h >= c { return held }
        if heldScore != nil, candidateScore == nil { return held }
        return candidate
    }

    /// `lineTimes` are seconds into the recording (the LRC stamps of lines that have words).
    /// `songStart` is where the broadcast says the cut began, `onsets` the curve from
    /// `SpectrumTimeline.onsets(channel:)`. Nil when there isn't enough to be sure.
    /// The usual few seconds first; only if the audio says nothing about those, the wider look that
    /// can still catch an LRC written for a different cut of the record.
    static func align(lineTimes: [Double], songStart: Date,
                      onsets: (start: Date, step: Double, values: [Float])) -> Alignment? {
        align(lineTimes: lineTimes, songStart: songStart, onsets: onsets, over: search)
            ?? align(lineTimes: lineTimes, songStart: songStart, onsets: onsets, over: wideSearch)
    }

    static func align(lineTimes: [Double], songStart: Date,
                      onsets: (start: Date, step: Double, values: [Float]),
                      over range: ClosedRange<Double>) -> Alignment? {
        guard let p = prepared(lineTimes: lineTimes, songStart: songStart, onsets: onsets) else { return nil }
        let (frames, curve, sums, step0) = p

        var scores = [(shift: Double, score: Double, lines: Int)]()
        var shift = range.lowerBound
        while shift <= range.upperBound {
            if let a = arrivalScore(shift, frames: frames, lineTimes: lineTimes,
                                    curve: curve, sums: sums, step: step0) {
                scores.append((shift, a.score, a.lines))
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
