//
//  BubbleStage.swift
//  StarPlayrKit
//
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  The equalizer's bubble setting, shared by every app: clicking or tapping the bars steps
//  Bubbles → Soft Bubbles → No Bubbles → Bubbles, remembered in UserDefaults ("bubbleStage").
//  ChatBubble is the little speech bubble that names the new stage.
//

import SwiftUI

public enum BubbleStage {
    /// UserDefaults key for the stage index; Soft Bubbles (`defaultStage`) until the user picks.
    public static let key = "bubbleStage"
    public static let defaultStage = 1
    public static let names = ["Bubbles", "Soft Bubbles", "No Bubbles"]
    private static let strengths = [0.90, 0.5, 0]

    public static func name(_ stage: Int) -> String { names[stage % 3] }
    /// Bubble strength handed to SpectrumRenderer.
    public static func strength(_ stage: Int) -> Double { strengths[stage % 3] }
    /// Full → half strength → off → full: each step fades out one notch, so it always does something visible.
    public static func next(_ stage: Int) -> Int { (stage + 1) % 3 }
}

/// A small speech bubble: a capsule with a tail pointing down.
public struct ChatBubble: View {
    let text: String
    let fontSize: CGFloat

    public init(text: String, fontSize: CGFloat = 11) {
        self.text = text
        self.fontSize = fontSize
    }

    public var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(.system(size: fontSize, weight: .semibold))
                .lineLimit(1)
                .fixedSize()   // never truncated to "…"
                .padding(.horizontal, fontSize * 8 / 11)
                .padding(.vertical, fontSize * 3 / 11)
                .background(.regularMaterial, in: Capsule())
            Tail().fill(.regularMaterial).frame(width: fontSize * 8 / 11, height: fontSize * 4 / 11)
        }
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .allowsHitTesting(false)
    }

    private struct Tail: Shape {
        func path(in r: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: r.minX, y: r.minY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
                p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
                p.closeSubpath()
            }
        }
    }
}
