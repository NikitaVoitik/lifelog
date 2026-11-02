// swift-tools-version: 6.2
// lifelog-asr: local transcription + speaker separation + voice fingerprints for Lifelog, on FluidAudio (CoreML / ANE).
import PackageDescription

let package = Package(
    name: "LifelogASR",
    platforms: [.macOS(.v15)],
    dependencies: [
        // ASR/VAD + diarization only (no TTS resources, no text-normalization binary)
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.0", traits: ["Diarizer"]),
    ],
    targets: [
        .executableTarget(
            name: "lifelog-asr",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
