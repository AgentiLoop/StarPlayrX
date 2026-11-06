//
//  SpectrumRenderer.swift
//  StarPlayrKit
//
//  Created by Todd Bruss on 10/31/26.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import MetalKit

/// AppKit/UIKit stays on main; frame preparation and drawable waits belong to the render worker.
@MainActor
public final class SpectrumRenderer: NSObject, MTKViewDelegate {
    public static let pad: Float = 18
    public static let barHeight: Float = 40
    public let device = MTLCreateSystemDefaultDevice()
    private lazy var worker = SpectrumRenderWorker(device: device)
    public var fixed = 0.025, bg = 0.025, light = false, bubbles = 0.5
    private var rendering = false

    public override init() { super.init() }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard !rendering, view.bounds.width > 0, view.bounds.height > 0,
              Self.isShowing(view),
              let layer = view.layer as? CAMetalLayer else { return }
        let frame = SpectrumRenderWorker.Input(
            surface: SpectrumRenderWorker.Surface(layer),
            width: Float(view.bounds.width), scale: Float(view.drawableSize.width / view.bounds.width),
            fixed: fixed, bg: bg, light: light, bubbles: bubbles, clearColor: view.clearColor)
        rendering = true
        worker.render(frame) { [weak self] in
            Task { @MainActor in self?.rendering = false }
        }
    }

    /// Starts or stops the view's 60 fps loop (both apps). Stopping draws one last frame, so the
    /// bars stay on screen frozen where they were instead of redrawing the same picture 60 times a second.
    public func setRunning(_ run: Bool, on view: MTKView) {
        guard view.isPaused == run else { return }
        view.isPaused = !run
        if !run { view.draw() }
    }

    /// Nothing is drawn into a window that is hidden or covered (Mac), or a view off screen.
    private static func isShowing(_ view: MTKView) -> Bool {
        guard let window = view.window else { return false }
        #if os(macOS)
        return window.isVisible && window.occlusionState.contains(.visible)
        #else
        return !window.isHidden
        #endif
    }
}

/// All mutable rendering state is owned by `renderQueue`, with at most one submitted CPU frame per view.
private final class SpectrumRenderWorker: @unchecked Sendable {
    /// AppKit owns layer geometry. The render worker only obtains drawables, never reads or mutates view properties.
    final class Surface: @unchecked Sendable {
        private let layer: CAMetalLayer
        init(_ layer: CAMetalLayer) { self.layer = layer }
        func nextDrawable() -> CAMetalDrawable? { layer.nextDrawable() }
    }
    struct Input {
        let surface: Surface
        let width, scale: Float
        let fixed, bg: Double
        let light: Bool
        let bubbles: Double
        let clearColor: MTLClearColor
    }
    struct Bar { var base, top, glow, shade, misc, curve: SIMD4<Float> }
    struct Globals { var view, state, bubble, blob, blobShape, glowStyle: SIMD4<Float> }

    private let device: MTLDevice?
    private lazy var queue = device?.makeCommandQueue()
    private lazy var pipeline: MTLRenderPipelineState? = {
        guard let device, let library = try? device.makeDefaultLibrary(bundle: .module) else { return nil }
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
    private var bars = [Bar]()
    private var blobColour = SIMD4<Float>(1, 1, 1, 1)
    private var builtGeneration = -1
    private var builtStyle = [Double]()
    private var clock = 0.0
    private let renderQueue = DispatchQueue(label: "com.starplayrx.spectrum.render", qos: .userInteractive)

    init(device: MTLDevice?) { self.device = device }
    private static func hue(_ x: Double) -> Double { (x.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) }

    func render(_ input: Input, completion: @escaping @Sendable () -> Void) {
        renderQueue.async {
            autoreleasepool {
                defer { completion() }
                self.draw(input)
            }
        }
    }

    private func draw(_ input: Input) {
        dispatchPrecondition(condition: .onQueue(renderQueue))
        guard let pipeline, let queue else { return }
        let viz = Visualizer.shared.frame
        let f = viz.fraction(now: CACurrentMediaTime())
        let fixed = input.fixed, bg = input.bg, light = input.light
        if viz.playing { clock = Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600) }
        let style = [fixed, bg, light ? 1 : 0]
        if viz.generation != builtGeneration || style != builtStyle {
            builtGeneration = viz.generation
            builtStyle = style
            let (topRatio, baseRatio, topSat, baseSat) = light ? (2.2, 1.9, 0.95, 1.0) : (4.5, 3.5, 0.75, 0.9)
            bars = viz.levels.indices.map { i -> Bar in
                let level = Double(viz.levels[i]), h = viz.hues[i]
                let top = ContrastColor.components(hue: Self.hue(h + 0.06 + 0.1 * level), saturation: topSat, against: fixed, minRatio: topRatio)
                return Bar(base: ContrastColor.components(hue: h, saturation: baseSat, against: fixed, minRatio: baseRatio),
                           top: top,
                           glow: ContrastColor.hsb(Self.hue(h + 0.1 + 0.35 * level), 1, 0.55 + 0.45 * bg),
                           shade: ContrastColor.hsb(h, 0.9, 1),
                           misc: [Float(level), Float(viz.rise[i]), viz.previous.levels[i], Float(viz.previous.rise[i])],
                           curve: [viz.history[0][i], viz.history[1][i], viz.history[2][i], viz.history[3][i]])
            }
            blobColour = ContrastColor.hsb(Self.hue(viz.hues[Visualizer.bandCount / 2] + 0.5), 0.8, 1)
        }
        let pulse = viz.previous.pulse + (viz.pulse - viz.previous.pulse) * Double(f)
        let blobX = viz.previous.blobX + (viz.blobX - viz.previous.blobX) * Double(f)
        var blob = blobColour
        blob.w = Float(0.075 + 0.175 * pulse)
        var globals = Globals(
            view: [input.width - 36, 40, input.scale, 18],
            state: [Float(pulse), light ? 1 : 0, Float(input.bubbles), Float(clock)],
            bubble: light ? [0, 0, 0, 0.7] : [1, 1, 1, 1],
            blob: blob,
            blobShape: [Float(80 * blobX), Float(0.6 + 0.3 * sin(viz.phase * 2 * .pi * 2)), Float(0.6 + 0.5 * pulse), 13],
            glowStyle: [Float(light ? 0.75 + 0.25 * pulse : 0.7 + 0.3 * pulse), Float(1 + 4 * pulse), f, 0])
        guard let drawable = input.surface.nextDrawable(), let commands = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = input.clearColor
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&globals, length: MemoryLayout<Globals>.stride, index: 0)
        bars.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { encoder.setFragmentBytes(base, length: bytes.count, index: 1) }
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
