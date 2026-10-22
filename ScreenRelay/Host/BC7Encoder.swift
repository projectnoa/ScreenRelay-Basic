//
//  BC7Encoder.swift
//  ScreenRelay
//
//  Real-time BC7 compression on the GPU. BC7 is a texture format GPUs sample
//  natively, so the target can display it without any decoding step. At one byte
//  per pixel, native 5K at 60 fps is ~7 Gbps, which a Thunderbolt Bridge carries.
//
//  The encoder uses BC7 mode 6 (one color line per 4×4 block, 16 blend levels).
//  Desktop content — grayscale-antialiased text, flat UI — is mostly two-color
//  blocks, which mode 6 reproduces almost exactly.
//

import Foundation
import CoreVideo
import Metal

enum BC7EncoderError: LocalizedError {
    case noMetalDevice
    case shaderCompilationFailed(String)
    case cannotWrapPixelBuffer

    var errorDescription: String? {
        switch self {
        case .noMetalDevice: "This Mac has no Metal GPU."
        case let .shaderCompilationFailed(message): "The BC7 shader failed to compile: \(message)"
        case .cannotWrapPixelBuffer: "A captured frame couldn't be handed to the GPU."
        }
    }
}

/// A rectangle measured in 4×4 blocks.
nonisolated struct BlockRect: Equatable {
    var x: Int, y: Int, width: Int, height: Int
}

/// The encoded picture plus a per-tile "changed" flag from the last encode.
///
/// The blocks buffer always holds the latest encoding of every block. Each encode
/// compares a block's new bits with the stored ones (the encoder is deterministic, so
/// unchanged pixels give identical bits) and only flags tiles that really changed.
nonisolated final class BC7Frame: @unchecked Sendable {
    /// Tiles are 64×64 pixels (16×16 blocks): small enough that a typed character
    /// sends ~4 KB, large enough to keep per-message overhead negligible.
    static let tileBlocks = 16

    let width: Int, height: Int
    let blocksWide: Int, blocksHigh: Int
    let tilesWide: Int, tilesHigh: Int
    let blocks: MTLBuffer
    let tileFlags: MTLBuffer

    init?(device: MTLDevice, width: Int, height: Int) {
        let count = BC7Encoder.blockCount(width: width, height: height)
        self.width = width
        self.height = height
        blocksWide = count.wide
        blocksHigh = count.high
        tilesWide = (count.wide + Self.tileBlocks - 1) / Self.tileBlocks
        tilesHigh = (count.high + Self.tileBlocks - 1) / Self.tileBlocks
        guard let blocks = device.makeBuffer(length: count.wide * count.high * BC7Encoder.bytesPerBlock, options: .storageModeShared),
              let flags = device.makeBuffer(length: tilesWide * tilesHigh, options: .storageModeShared) else { return nil }
        self.blocks = blocks
        self.tileFlags = flags
    }

    /// Rows of 16 bytes per block, `blocksWide` blocks per row.
    var bytesPerBlockRow: Int { blocksWide * BC7Encoder.bytesPerBlock }
}

nonisolated final class BC7Encoder: @unchecked Sendable {
    static let blockSize = 4
    static let bytesPerBlock = 16

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private let scratchFlags: MTLBuffer

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw BC7EncoderError.noMetalDevice
        }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw BC7EncoderError.shaderCompilationFailed("\(error)")
        }
        guard let function = library.makeFunction(name: "encodeBC7Mode6") else {
            throw BC7EncoderError.shaderCompilationFailed("missing kernel")
        }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let cache else { throw BC7EncoderError.noMetalDevice }

        self.device = device
        self.queue = queue
        self.pipeline = try device.makeComputePipelineState(function: function)
        self.textureCache = cache
        guard let scratch = device.makeBuffer(length: 16, options: .storageModeShared) else { throw BC7EncoderError.noMetalDevice }
        self.scratchFlags = scratch
    }

    /// Blocks needed to cover a frame of the given pixel size.
    static func blockCount(width: Int, height: Int) -> (wide: Int, high: Int) {
        ((width + blockSize - 1) / blockSize, (height + blockSize - 1) / blockSize)
    }

    func makeFrame(width: Int, height: Int) -> BC7Frame? {
        BC7Frame(device: device, width: width, height: height)
    }

    /// Encodes a whole BGRA frame into `frame`, flagging the tiles whose blocks changed.
    /// Calls `completion` when the GPU has finished.
    func encode(_ pixelBuffer: CVPixelBuffer, into frame: BC7Frame,
                completion: @escaping @Sendable (_ gpuSeconds: Double) -> Void) throws {
        let blocks = Self.blockCount(width: frame.width, height: frame.height)
        try encode(pixelBuffer, regions: [BlockRect(x: 0, y: 0, width: blocks.wide, height: blocks.high)],
                   blocks: frame.blocks, tileFlags: frame.tileFlags, tilesWide: frame.tilesWide, completion: completion)
    }

    /// Encodes the given block regions of a BGRA frame into `output`, at each block's
    /// position in the full frame. Calls `completion` when the GPU has finished.
    func encode(_ pixelBuffer: CVPixelBuffer, regions: [BlockRect], into output: MTLBuffer,
                completion: @escaping @Sendable (_ gpuSeconds: Double) -> Void) throws {
        try encode(pixelBuffer, regions: regions, blocks: output, tileFlags: nil, tilesWide: 0, completion: completion)
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, regions: [BlockRect], blocks output: MTLBuffer,
                        tileFlags: MTLBuffer?, tilesWide: Int,
                        completion: @escaping @Sendable (_ gpuSeconds: Double) -> Void) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                                                  .bgra8Unorm, width, height, 0, &cvTexture)
        guard let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture),
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder() else {
            throw BC7EncoderError.cannotWrapPixelBuffer
        }
        let frameBlocks = Self.blockCount(width: width, height: height)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(output, offset: 0, index: 0)
        // Without a flags buffer, bind a scratch one; the kernel then just writes blocks.
        encoder.setBuffer(tileFlags ?? scratchFlags, offset: 0, index: 2)

        let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 1)
        for region in regions where region.width > 0 && region.height > 0 {
            var params: [UInt32] = [UInt32(region.x), UInt32(region.y), UInt32(region.width), UInt32(region.height),
                                    UInt32(frameBlocks.wide), UInt32(frameBlocks.high), UInt32(width), UInt32(height),
                                    UInt32(tileFlags == nil ? 0 : tilesWide), UInt32(BC7Frame.tileBlocks)]
            encoder.setBytes(&params, length: params.count * MemoryLayout<UInt32>.size, index: 1)
            encoder.dispatchThreads(MTLSize(width: region.width, height: region.height, depth: 1),
                                    threadsPerThreadgroup: threadsPerGroup)
        }
        encoder.endEncoding()
        // Only retained so the IOSurface outlives the GPU work; never used concurrently.
        nonisolated(unsafe) let retainedTexture = cvTexture
        commands.addCompletedHandler { buffer in
            // Keep the CoreVideo texture (and so the IOSurface) alive until the GPU is done.
            withExtendedLifetime(retainedTexture) {}
            completion(buffer.gpuEndTime - buffer.gpuStartTime)
        }
        commands.commit()
    }

    // MARK: - Shader

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params {
        uint2 origin;        // region origin, in blocks
        uint2 size;          // region size, in blocks
        uint2 frameBlocks;   // frame size, in blocks (row stride of the output)
        uint2 framePixels;   // frame size, in pixels
        uint2 tiles;         // tiles per row (0 = don't track changes), blocks per tile side
    };

    constant int kWeights[16] = { 0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64 };

    // Quantizes an endpoint (0…255) to 7 bits plus a shared p-bit, picking the p-bit
    // that reproduces it best. Returns the 7-bit values; `pbit` receives the p-bit.
    static uint3 quantizeEndpoint(float3 e, thread uint &pbit) {
        float bestError = INFINITY;
        uint3 best = 0;
        for (uint p = 0; p < 2; ++p) {
            uint3 q = uint3(clamp(round((e - float(p)) * 0.5f), 0.0f, 127.0f));
            float3 recon = float3(q * 2 + p);
            float error = distance_squared(recon, e);
            if (error < bestError) { bestError = error; best = q; pbit = p; }
        }
        return best;
    }

    // Picks the best of the 16 blend levels for every pixel; returns the total error.
    static float chooseIndices(thread const float3 *pixels, int3 c0, int3 c1, thread uint *indices) {
        float3 palette[16];
        for (int i = 0; i < 16; ++i) {
            int w = kWeights[i];
            palette[i] = float3(((64 - w) * c0 + w * c1 + 32) >> 6);
        }
        float total = 0;
        for (int p = 0; p < 16; ++p) {
            float best = INFINITY;
            uint bestIndex = 0;
            for (uint i = 0; i < 16; ++i) {
                float d = distance_squared(pixels[p], palette[i]);
                if (d < best) { best = d; bestIndex = i; }
            }
            indices[p] = bestIndex;
            total += best;
        }
        return total;
    }

    struct Candidate {
        uint3 q0, q1;
        uint p0, p1;
        uint indices[16];
        float error;
    };

    static Candidate evaluate(thread const float3 *pixels, float3 e0, float3 e1) {
        Candidate c;
        c.q0 = quantizeEndpoint(clamp(e0, 0.0f, 255.0f), c.p0);
        c.q1 = quantizeEndpoint(clamp(e1, 0.0f, 255.0f), c.p1);
        int3 c0 = int3(c.q0 * 2 + c.p0), c1 = int3(c.q1 * 2 + c.p1);
        c.error = chooseIndices(pixels, c0, c1, c.indices);
        return c;
    }

    static void putBits(thread uint *words, thread uint &position, uint value, uint count) {
        uint word = position >> 5, offset = position & 31;
        words[word] |= value << offset;
        if (offset + count > 32) { words[word + 1] |= value >> (32 - offset); }
        position += count;
    }

    kernel void encodeBC7Mode6(texture2d<float, access::read> source [[texture(0)]],
                               device uint4 *output [[buffer(0)]],
                               constant Params &params [[buffer(1)]],
                               device uchar *tileFlags [[buffer(2)]],
                               uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= params.size.x || gid.y >= params.size.y) { return; }
        uint2 block = params.origin + gid;
        if (block.x >= params.frameBlocks.x || block.y >= params.frameBlocks.y) { return; }

        // Load the 4×4 block (edges are clamped to the frame).
        float3 pixels[16];
        float3 mean = 0;
        for (uint y = 0; y < 4; ++y) {
            for (uint x = 0; x < 4; ++x) {
                uint2 coord = min(block * 4 + uint2(x, y), params.framePixels - 1);
                float3 rgb = source.read(coord).rgb * 255.0f;
                pixels[y * 4 + x] = rgb;
                mean += rgb;
            }
        }
        mean /= 16.0f;

        // Principal color direction (power iteration on the covariance matrix).
        float3 d0 = 0, d1 = 0; // xx, yy, zz and xy, xz, yz
        for (int i = 0; i < 16; ++i) {
            float3 d = pixels[i] - mean;
            d0 += d * d;
            d1 += float3(d.x * d.y, d.x * d.z, d.y * d.z);
        }
        float3 axis = float3(0.577f);
        for (int i = 0; i < 4; ++i) {
            float3 next = float3(d0.x * axis.x + d1.x * axis.y + d1.y * axis.z,
                                 d1.x * axis.x + d0.y * axis.y + d1.z * axis.z,
                                 d1.y * axis.x + d1.z * axis.y + d0.z * axis.z);
            float len = length(next);
            if (len < 1e-6f) { break; }
            axis = next / len;
        }
        float tMin = INFINITY, tMax = -INFINITY;
        for (int i = 0; i < 16; ++i) {
            float t = dot(pixels[i] - mean, axis);
            tMin = min(tMin, t);
            tMax = max(tMax, t);
        }

        Candidate best = evaluate(pixels, mean + axis * tMin, mean + axis * tMax);

        // One least-squares refit of the endpoints for the chosen blend levels.
        if (best.error > 0) {
            float a = 0, b = 0, c = 0;
            float3 x0 = 0, x1 = 0;
            for (int i = 0; i < 16; ++i) {
                float w = float(kWeights[best.indices[i]]) / 64.0f;
                a += (1 - w) * (1 - w);
                b += (1 - w) * w;
                c += w * w;
                x0 += (1 - w) * pixels[i];
                x1 += w * pixels[i];
            }
            float det = a * c - b * b;
            if (abs(det) > 1e-6f) {
                float3 e0 = (c * x0 - b * x1) / det;
                float3 e1 = (a * x1 - b * x0) / det;
                Candidate refined = evaluate(pixels, e0, e1);
                if (refined.error < best.error) { best = refined; }
            }
        }

        // The first pixel's index is stored with 3 bits, so its top bit must be 0:
        // if needed, swap the endpoints and mirror every index.
        if (best.indices[0] >= 8) {
            uint3 q = best.q0; best.q0 = best.q1; best.q1 = q;
            uint p = best.p0; best.p0 = best.p1; best.p1 = p;
            for (int i = 0; i < 16; ++i) { best.indices[i] = 15 - best.indices[i]; }
        }

        // Pack: mode 6 marker, R0 R1 G0 G1 B0 B1 A0 A1 (7 bits each), P0 P1, indices.
        uint words[4] = { 0, 0, 0, 0 };
        uint position = 0;
        putBits(words, position, 1u << 6, 7);
        putBits(words, position, best.q0.x, 7); putBits(words, position, best.q1.x, 7);
        putBits(words, position, best.q0.y, 7); putBits(words, position, best.q1.y, 7);
        putBits(words, position, best.q0.z, 7); putBits(words, position, best.q1.z, 7);
        putBits(words, position, 127, 7);       putBits(words, position, 127, 7); // opaque
        putBits(words, position, best.p0, 1);   putBits(words, position, best.p1, 1);
        putBits(words, position, best.indices[0], 3);
        for (int i = 1; i < 16; ++i) { putBits(words, position, best.indices[i], 4); }

        uint4 encoded = uint4(words[0], words[1], words[2], words[3]);
        uint index = block.y * params.frameBlocks.x + block.x;
        if (params.tiles.x == 0) {
            output[index] = encoded;
        } else if (any(output[index] != encoded)) {
            // Only changed blocks are written, so the buffer always holds the latest
            // picture, and their tile is flagged for sending.
            output[index] = encoded;
            tileFlags[(block.y / params.tiles.y) * params.tiles.x + block.x / params.tiles.y] = 1;
        }
    }
    """
}
