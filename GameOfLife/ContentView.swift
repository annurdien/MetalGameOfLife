//
//  ContentView.swift
//  Metal
//
//  Created by Annurdien Rasyid on 23/04/26.
//

import SwiftUI

struct ContentView: View {
    @State private var isRunning = true
    @State private var generationsPerSecond: Float = 18

    // These counters trigger one-shot actions in MetalGameOfLifeView.
    // Incrementing changes value identity, which updateUIView can observe.
    @State private var randomizeTrigger = 0
    @State private var clearTrigger = 0
    @State private var stepTrigger = 0

    var body: some View {
        VStack(spacing: 14) {
            MetalGameOfLifeView(
                isRunning: $isRunning,
                generationsPerSecond: $generationsPerSecond,
                randomizeTrigger: randomizeTrigger,
                clearTrigger: clearTrigger,
                stepTrigger: stepTrigger
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            )
            .padding(.horizontal)

            HStack(spacing: 10) {
                Button(isRunning ? "Pause" : "Play") {
                    isRunning.toggle()
                }
                .buttonStyle(.glass)

                Button("Step") {
                    stepTrigger &+= 1
                }
                .buttonStyle(.glass)
                .disabled(isRunning)

                Button("Randomize") {
                    randomizeTrigger &+= 1
                }
                .buttonStyle(.glass)

                Button("Clear") {
                    isRunning = false
                    clearTrigger &+= 1
                }
                .buttonStyle(.glass)
            }
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Speed")
                    Spacer()
                    Text("\(Int(generationsPerSecond)) gen/s")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Slider(value: $generationsPerSecond, in: 1...60, step: 1)
            }
            .padding(.horizontal)

        }
        .padding(.vertical)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.05, blue: 0.08),
                    Color(red: 0.06, green: 0.07, blue: 0.11)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }
}

#Preview {
    ContentView()
}
