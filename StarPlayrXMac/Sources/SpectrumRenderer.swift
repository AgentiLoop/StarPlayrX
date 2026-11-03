//
//  SpectrumRenderer.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 10/31/26.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import MetalKit

/// Reads the visualizer state each frame and hands it to the shader: colours are worked out here
/// (24 bars, a few contrast checks each), all per-pixel work runs on the GPU.
@MainActor
final class SpectrumRenderer: NSObject, MTKViewDelegate {
    /// Points the Metal view overhangs the bars on each side, for the glow and the blob.
    static let pad: Float = 18
    /// Height of the tallest bar, in points (was 28).
    static let barHeight: Float = 40

    struct Bar { var base, top, glow, shade, misc, curve: SIMD4<Float> }   // misc: level, rise, previous level, previous rise; curve: last four levels
    struct Globals { var view, state, bubble, blob, blobShape, glowStyle: SIMD4<Float> }

    /// No Metal device, or a shader (Spectrum.metal) that fails to load, leaves these nil: the bars
    /// just don't draw, instead of crashing the app.
    let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()
    private lazy var pipeline: MTLRenderPipelineState? = {
        guard let device, let library = device.makeDefaultLibrary() else { return nil }
        do {
            var bands = Int32(Visualizer.bandCount)
            let constants = MTLFunctionConstantValues()
            constants.setConstantValue(&bands, type: .int, index: 0)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "spectrumVertex")
            desc.fragmentFunction = try library.makeFunction(name: "spectrumFragment", constantValues: constants)
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("StarPlayrX spectrum shader failed: \(error)")
            return nil
        }
    }()
    var fixed = 0.025, bg = 0.025, light = false, bubbles = 0.5
    private var bars = [Bar]()
    private var blobColour = SIMD4<Float>(1, 1, 1, 1)
    private var builtGeneration = -1
    private var builtStyle = [Double]()

    private static func hue(_ x: Double) -> Double { (x.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // A hidden, occluded or rolled-up window doesn't hand drawables back, so asking for one would
        // block the main thread for up to a second each frame.
        guard view.bounds.width > 0, view.bounds.height > 0, let window = view.window,
              window.isVisible, window.occlusionState.contains(.visible),
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let pipeline, let commands = queue?.makeCommandBuffer(), let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        let viz = Visualizer.shared
        let f = viz.tick(now: CACurrentMediaTime())
        let style = [fixed, bg, light ? 1 : 0]
        if viz.generation != builtGeneration || style != builtStyle {
            builtGeneration = viz.generation
            builtStyle = style
            // Light panel: a gentler contrast target and full saturation, so darkening stops while the
            // colours are still juicy instead of sinking to olive and navy.
            let (topRatio, baseRatio, topSat, baseSat) = light ? (2.2, 1.9, 0.95, 1.0) : (4.5, 3.5, 0.75, 0.9)
            bars = viz.levels.indices.map { i -> Bar in
                let level = Double(viz.levels[i]), h = viz.hues[i]
                let top = ContrastColor.components(hue: Self.hue(h + 0.06 + 0.1 * level), saturation: topSat, against: fixed, minRatio: topRatio)
                return Bar(base: ContrastColor.components(hue: h, saturation: baseSat, against: fixed, minRatio: baseRatio),
                           top: top,
                           glow: ContrastColor.hsb(Self.hue(h + 0.1 + 0.35 * level), 1, 0.55 + 0.45 * bg),   // lighter background, lighter glow; fully saturated
                           shade: ContrastColor.hsb(h, 0.9, 1),   // the bar's pure colour, not contrast-darkened
                           // The GPU tweens level and bubble rise from the previous step to this one.
                           misc: [Float(level), Float(viz.rise[i]), viz.previous.levels[i], Float(viz.previous.rise[i])],
                           curve: [viz.history[0][i], viz.history[1][i], viz.history[2][i], viz.history[3][i]])
            }
            blobColour = ContrastColor.hsb(Self.hue(viz.hues[Visualizer.bandCount / 2] + 0.5), 0.8, 1)
        }
        // A handful of scalars: tweened here.
        let pulse = viz.previous.pulse + (viz.pulse - viz.previous.pulse) * Double(f)
        let blobX = viz.previous.blobX + (viz.blobX - viz.previous.blobX) * Double(f)
        // The "lava": a blurred blob of the colour opposite the middle bar's, swelling on the beat.
        var blob = blobColour
        blob.w = Float(0.075 + 0.175 * pulse)
        var globals = Globals(
            view: [Float(view.bounds.width) - 2 * Self.pad, Self.barHeight, Float(view.drawableSize.width / view.bounds.width), Self.pad],
            state: [Float(pulse), light ? 1 : 0, Float(bubbles), Float(Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))],
            bubble: light ? [0, 0, 0, 0.7] : [1, 1, 1, 1],   // dark bubbles at 70% strength, so they stay soft
            blob: blob,
            blobShape: [Float(80 * blobX), Float(0.6 + 0.3 * sin(viz.phase * 2 * .pi * 2)), Float(0.6 + 0.5 * pulse), 13],   // last: glow moved 13 pt down
            glowStyle: [Float(light ? 0.75 + 0.25 * pulse : 0.7 + 0.3 * pulse), Float(1 + 4 * pulse), f, 0])
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&globals, length: MemoryLayout<Globals>.stride, index: 0)
        encoder.setFragmentBytes(&bars, length: MemoryLayout<Bar>.stride * bars.count, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
