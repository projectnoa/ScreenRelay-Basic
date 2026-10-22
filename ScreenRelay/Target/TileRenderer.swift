//
//  TileRenderer.swift
//  ScreenRelay
//
//  Displays the native-quality BC7 stream. Received tiles are copied straight into a
//  BC7 texture, which the GPU samples natively — there's no decoding step at all —
//  and each finished frame is drawn into a CAMetalLayer.
//

import Foundation
import Metal
import QuartzCore
import CoreGraphics

nonisolated final class TileRenderer: @unchecked Sendable {
    let layer: CAMetalLayer

    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private let sampler: MTLSamplerState?
    private let renderQueue = DispatchQueue(label: "ScreenRelay.tiles.render", qos: .userInteractive)
    private let lock = NSLock()

    private var canvas: MTLTexture?
    /// Frames finished by the host but not yet drawn; drawing one covers them all.
    private var pendingAcks = 0
    private var drawScheduled = false
    private var firstPendingFrameTime: CFAbsoluteTime?

    /// Called with the number of frames drawn and the time it took (µs), once the GPU is done.
    var onFramesDrawn: (@Sendable (_ count: Int, _ microseconds: UInt32) -> Void)?

    /// True if this Mac's GPU can sample BC7 textures.
    static var isSupported: Bool {
        MTLCreateSystemDefaultDevice()?.supportsBCTextureCompression ?? false
    }

    @MainActor
    init() {
        layer = CAMetalLayer()
        // The GPU driving the main display (the 2017 iMac's Radeon) avoids cross-GPU copies.
        let displayID = CGMainDisplayID()
        device = CGDirectDisplayCopyCurrentMetalDevice(displayID) ?? MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        // Captured pixels are sRGB; tag them so they're shown without conversion.
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        var pipeline: MTLRenderPipelineState?
        var sampler: MTLSamplerState?
        if let device {
            do {
                let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "canvasVertex")
                descriptor.fragmentFunction = library.makeFunction(name: "canvasFragment")
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                print("[TileRenderer] Shader setup failed: \(error)")
            }
            let samplerDescriptor = MTLSamplerDescriptor()
            samplerDescriptor.minFilter = .linear
            samplerDescriptor.magFilter = .linear
            sampler = device.makeSamplerState(descriptor: samplerDescriptor)
        }
        self.pipeline = pipeline
        self.sampler = sampler
    }

    /// Drops the canvas between sessions.
    func reset() {
        lock.withLock {
            canvas = nil
            pendingAcks = 0
            firstPendingFrameTime = nil
        }
    }

    // MARK: - Messages (network queue)

    func setCanvas(_ payload: Data) {
        var reader = ByteReader(payload)
        guard let device, let width = reader.readUInt32(), let height = reader.readUInt32(),
              width > 0, height > 0 else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bc7_rgbaUnorm, width: Int(width), height: Int(height), mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .managed
        let texture = device.makeTexture(descriptor: descriptor)
        lock.withLock { canvas = texture }
        print("[TileRenderer] Canvas \(width)×\(height) BC7")
    }

    func applyTiles(_ payload: Data) {
        guard let run = TileRun(payload), let canvas = lock.withLock({ canvas }) else { return }
        let x = run.blockX * 4, y = run.blockY * 4
        guard x < canvas.width, y < canvas.height else { return }
        // Edge tiles may extend past a frame size that isn't a multiple of 4.
        let width = min(run.blocksWide * 4, canvas.width - x)
        let height = min(run.blocksHigh * 4, canvas.height - y)
        run.data.withUnsafeBytes { bytes in
            canvas.replace(region: MTLRegionMake2D(x, y, width, height), mipmapLevel: 0,
                           withBytes: bytes.baseAddress!, bytesPerRow: run.blocksWide * 16)
        }
    }

    /// All tiles of a frame have arrived: draw (coalescing frames if drawing is behind).
    func frameEnded() {
        let schedule = lock.withLock { () -> Bool in
            pendingAcks += 1
            if firstPendingFrameTime == nil { firstPendingFrameTime = CFAbsoluteTimeGetCurrent() }
            defer { drawScheduled = true }
            return !drawScheduled
        }
        if schedule {
            renderQueue.async { [weak self] in self?.draw() }
        }
    }

    // MARK: - Drawing (render queue)

    private func draw() {
        let (count, started, canvas) = lock.withLock { () -> (Int, CFAbsoluteTime, MTLTexture?) in
            defer {
                pendingAcks = 0
                drawScheduled = false
                firstPendingFrameTime = nil
            }
            return (pendingAcks, firstPendingFrameTime ?? CFAbsoluteTimeGetCurrent(), self.canvas)
        }
        guard count > 0 else { return }
        let report: @Sendable () -> Void = { [weak self] in
            let micros = UInt32(min(max((CFAbsoluteTimeGetCurrent() - started) * 1_000_000, 1), Double(UInt32.max)))
            self?.onFramesDrawn?(count, micros)
        }

        let scale = layer.contentsScale
        let drawableSize = CGSize(width: layer.bounds.width * scale, height: layer.bounds.height * scale)
        guard let canvas, let queue, let pipeline, drawableSize.width > 0, drawableSize.height > 0 else {
            report()
            return
        }
        if layer.drawableSize != drawableSize { layer.drawableSize = drawableSize }

        guard let drawable = layer.nextDrawable(), let commands = queue.makeCommandBuffer() else {
            report() // e.g. the window is on another Space; still release the host's frames
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        // Letterbox the canvas into the drawable, preserving its aspect ratio.
        let canvasAspect = Double(canvas.width) / Double(canvas.height)
        let drawableAspect = drawableSize.width / drawableSize.height
        var scaleXY: [Float] = canvasAspect > drawableAspect
            ? [1, Float(drawableAspect / canvasAspect)]
            : [Float(canvasAspect / drawableAspect), 1]

        if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&scaleXY, length: MemoryLayout<Float>.size * 2, index: 0)
            encoder.setFragmentTexture(canvas, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }
        commands.present(drawable)
        commands.addCompletedHandler { _ in report() }
        commands.commit()
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut canvasVertex(uint id [[vertex_id]], constant float2 &scale [[buffer(0)]]) {
        float2 corner = float2(id & 1, id >> 1);           // (0,0) (1,0) (0,1) (1,1)
        VertexOut out;
        out.position = float4((corner * 2 - 1) * scale * float2(1, -1), 0, 1);
        out.uv = corner;                                   // texture origin is top-left
        return out;
    }

    fragment float4 canvasFragment(VertexOut in [[stage_in]],
                                   texture2d<float> canvas [[texture(0)]],
                                   sampler linearSampler [[sampler(0)]]) {
        return float4(canvas.sample(linearSampler, in.uv).rgb, 1);
    }
    """
}
