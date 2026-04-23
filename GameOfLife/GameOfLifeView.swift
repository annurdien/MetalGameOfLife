import MetalKit
import SwiftUI

/// SwiftUI wrapper around MTKView.
///
/// The integer trigger values are monotonic counters used to send one-shot
/// commands (randomize/clear/step) from SwiftUI into the imperative renderer.
struct MetalGameOfLifeView: UIViewRepresentable {
    @Binding var isRunning: Bool
    @Binding var generationsPerSecond: Float

    var randomizeTrigger: Int
    var clearTrigger: Int
    var stepTrigger: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        // Continuous drawing lets the renderer advance simulation at its own pace.
        let mtkView = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1.0)
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.framebufferOnly = false

        guard let renderer = GameOfLifeRenderer(mtkView: mtkView) else {
            assertionFailure("Unable to initialize Game of Life Metal renderer")
            return mtkView
        }

        renderer.isRunning = isRunning
        renderer.generationsPerSecond = generationsPerSecond

        context.coordinator.renderer = renderer
        mtkView.delegate = renderer

        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else {
            return
        }

        // Keep long-lived renderer state in sync with declarative SwiftUI bindings.
        renderer.isRunning = isRunning
        renderer.generationsPerSecond = generationsPerSecond

        if context.coordinator.lastRandomizeTrigger != randomizeTrigger {
            context.coordinator.lastRandomizeTrigger = randomizeTrigger
            renderer.randomize(seed: UInt32.random(in: 1...UInt32.max))
        }

        if context.coordinator.lastClearTrigger != clearTrigger {
            context.coordinator.lastClearTrigger = clearTrigger
            renderer.clearGrid()
        }

        if context.coordinator.lastStepTrigger != stepTrigger {
            context.coordinator.lastStepTrigger = stepTrigger
            renderer.stepSingleGeneration()
        }
    }

    final class Coordinator {
        var renderer: GameOfLifeRenderer?
        var lastRandomizeTrigger: Int = 0
        var lastClearTrigger: Int = 0
        var lastStepTrigger: Int = 0
    }
}
