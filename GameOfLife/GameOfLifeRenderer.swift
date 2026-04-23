import MetalKit
import QuartzCore

/// GPU-backed Conway's Game of Life renderer.
///
/// Per frame:
/// 1) Run zero or more compute steps (state update).
/// 2) Render the latest state texture to a fullscreen quad.
final class GameOfLifeRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    private let stepPipeline: MTLComputePipelineState
    private let seedPipeline: MTLComputePipelineState
    private let clearPipeline: MTLComputePipelineState
    private let renderPipeline: MTLRenderPipelineState

    private let seedThreadsPerThreadgroup: MTLSize
    private let clearThreadsPerThreadgroup: MTLSize
    private let stepThreadsPerThreadgroup: MTLSize
    private let threadsPerGrid: MTLSize

    // Ping-pong textures: read from current, write into next, then swap indices.
    private var stateTextures: [MTLTexture] = []
    private var currentTextureIndex = 0

    // Simulation clock accumulator so simulation speed is independent from render FPS.
    private var accumulator: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval?

    private(set) var generation: UInt64 = 0

    var isRunning = true
    var generationsPerSecond: Float = 20

    /// Builds compute/render pipelines and allocates simulation textures.
    init?(mtkView: MTKView, gridDimension: Int = 256) {
        guard
            let resolvedDevice = mtkView.device ?? MTLCreateSystemDefaultDevice(),
            let resolvedQueue = resolvedDevice.makeCommandQueue(),
            let library = resolvedDevice.makeDefaultLibrary(),
            let stepFunction = library.makeFunction(name: "stepLife"),
            let seedFunction = library.makeFunction(name: "seedRandom"),
            let clearFunction = library.makeFunction(name: "clearState"),
            let vertexFunction = library.makeFunction(name: "lifeVertex"),
            let fragmentFunction = library.makeFunction(name: "lifeFragment")
        else {
            return nil
        }

        do {
            stepPipeline = try resolvedDevice.makeComputePipelineState(function: stepFunction)
            seedPipeline = try resolvedDevice.makeComputePipelineState(function: seedFunction)
            clearPipeline = try resolvedDevice.makeComputePipelineState(function: clearFunction)

            let renderDescriptor = MTLRenderPipelineDescriptor()
            renderDescriptor.vertexFunction = vertexFunction
            renderDescriptor.fragmentFunction = fragmentFunction
            renderDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            renderPipeline = try resolvedDevice.makeRenderPipelineState(descriptor: renderDescriptor)
        } catch {
            assertionFailure("Failed to create Metal pipeline states: \(error)")
            return nil
        }

        guard let textures = Self.makeStateTextures(device: resolvedDevice, dimension: gridDimension) else {
            return nil
        }

        device = resolvedDevice
        commandQueue = resolvedQueue
        stateTextures = textures
        seedThreadsPerThreadgroup = Self.bestThreadgroupSize(for: seedPipeline)
        clearThreadsPerThreadgroup = Self.bestThreadgroupSize(for: clearPipeline)
        stepThreadsPerThreadgroup = Self.bestThreadgroupSize(for: stepPipeline)
        threadsPerGrid = MTLSize(width: gridDimension, height: gridDimension, depth: 1)

        super.init()

        randomize(seed: UInt32.random(in: 1...UInt32.max))
    }

    /// Allocates two writable textures so each generation can be computed out-of-place.
    static func makeStateTextures(device: MTLDevice, dimension: Int) -> [MTLTexture]? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: dimension,
            height: dimension,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private

        guard
            let first = device.makeTexture(descriptor: descriptor),
            let second = device.makeTexture(descriptor: descriptor)
        else {
            return nil
        }

        return [first, second]
    }

    /// Picks a legal threadgroup size for the pipeline and current device limits.
    private static func bestThreadgroupSize(for pipeline: MTLComputePipelineState) -> MTLSize {
        let executionWidth = max(1, pipeline.threadExecutionWidth)
        let maxThreads = max(1, pipeline.maxTotalThreadsPerThreadgroup)

        let width = min(16, executionWidth)
        let height = max(1, min(16, maxThreads / width))

        return MTLSize(width: width, height: height, depth: 1)
    }

    private var currentStateTexture: MTLTexture {
        stateTextures[currentTextureIndex]
    }

    private var nextStateTexture: MTLTexture {
        stateTextures[(currentTextureIndex + 1) % stateTextures.count]
    }

    /// Fills the grid with pseudo-random alive/dead cells.
    func randomize(seed: UInt32) {
        performComputePass { commandBuffer in
            encodeSeed(texture: stateTextures[0], seed: seed, commandBuffer: commandBuffer)
            encodeSeed(texture: stateTextures[1], seed: seed, commandBuffer: commandBuffer)
        }

        generation = 0
        accumulator = 0
    }

    /// Clears both textures so simulation starts from an empty world.
    func clearGrid() {
        performComputePass { commandBuffer in
            encodeClear(texture: stateTextures[0], commandBuffer: commandBuffer)
            encodeClear(texture: stateTextures[1], commandBuffer: commandBuffer)
        }

        generation = 0
        accumulator = 0
    }

    /// Runs exactly one generation update (useful when paused).
    func stepSingleGeneration() {
        performComputePass { [self] commandBuffer in
            encodeStep(commandBuffer: commandBuffer)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // The simulation grid is fixed and independent of the drawable size.
    }

    /// Draw callback from MTKView.
    func draw(in view: MTKView) {
        guard
            let renderPassDescriptor = view.currentRenderPassDescriptor,
            let currentDrawable = view.currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }

        updateSimulation(commandBuffer: commandBuffer)

        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
            renderEncoder.setRenderPipelineState(renderPipeline)
            renderEncoder.setFragmentTexture(currentStateTexture, index: 0)
            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            renderEncoder.endEncoding()
        }

        commandBuffer.present(currentDrawable)
        commandBuffer.commit()
    }

    private func updateSimulation(commandBuffer: MTLCommandBuffer) {
        let now = CACurrentMediaTime()

        guard let lastTimestamp else {
            self.lastTimestamp = now
            return
        }

        let delta = now - lastTimestamp
        self.lastTimestamp = now

        guard isRunning else {
            return
        }

        accumulator += delta

        // dt_per_generation = 1 / generationsPerSecond
        let clampedSpeed = max(1.0, Double(generationsPerSecond))
        let stepInterval = 1.0 / clampedSpeed

        var stepsThisFrame = 0
        while accumulator >= stepInterval && stepsThisFrame < 8 {
            encodeStep(commandBuffer: commandBuffer)
            accumulator -= stepInterval
            stepsThisFrame += 1
        }

        if stepsThisFrame == 8 {
            accumulator = 0
        }
    }

    /// Creates a short-lived command buffer for one-off compute operations.
    private func performComputePass(_ encode: (MTLCommandBuffer) -> Void) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        encode(commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func encodeSeed(texture: MTLTexture, seed: UInt32, commandBuffer: MTLCommandBuffer) {
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        var mutableSeed = seed

        computeEncoder.setComputePipelineState(seedPipeline)
        computeEncoder.setTexture(texture, index: 0)
        computeEncoder.setBytes(&mutableSeed, length: MemoryLayout<UInt32>.size, index: 0)
        dispatchGrid(
            with: computeEncoder,
            threadsPerThreadgroup: seedThreadsPerThreadgroup
        )
        computeEncoder.endEncoding()
    }

    private func encodeClear(texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        computeEncoder.setComputePipelineState(clearPipeline)
        computeEncoder.setTexture(texture, index: 0)
        dispatchGrid(
            with: computeEncoder,
            threadsPerThreadgroup: clearThreadsPerThreadgroup
        )
        computeEncoder.endEncoding()
    }

    private func encodeStep(commandBuffer: MTLCommandBuffer) {
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        computeEncoder.setComputePipelineState(stepPipeline)
        computeEncoder.setTexture(currentStateTexture, index: 0)
        computeEncoder.setTexture(nextStateTexture, index: 1)
        dispatchGrid(
            with: computeEncoder,
            threadsPerThreadgroup: stepThreadsPerThreadgroup
        )
        computeEncoder.endEncoding()

        currentTextureIndex = (currentTextureIndex + 1) % stateTextures.count
        generation += 1
    }

    /// Dispatches enough threadgroups to cover the full grid (ceil division).
    /// Kernels guard out-of-range thread IDs, so over-dispatch is safe.
    private func dispatchGrid(with encoder: MTLComputeCommandEncoder, threadsPerThreadgroup: MTLSize) {
        let threadgroupCount = MTLSize(
            width: (threadsPerGrid.width + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
            height: (threadsPerGrid.height + threadsPerThreadgroup.height - 1) / threadsPerThreadgroup.height,
            depth: 1
        )

        encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadsPerThreadgroup)
    }
}
