// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceMemoModules",
    defaultLocalization: "ja",
    // PackageDescription 6.0 does not expose the v26 manifest constants yet.
    // The app targets set the actual iOS/watchOS 26 deployment targets.
    platforms: [
        .macOS(.v14),
        .iOS(.v18),
        .watchOS(.v11)
    ],
    products: [
        .library(name: "VoiceMemoDomain", targets: ["VoiceMemoDomain"]),
        .library(name: "VoiceMemoInterfaces", targets: ["VoiceMemoInterfaces"]),
        .library(name: "SyncContract", targets: ["SyncContract"]),
        .library(name: "RecordingFeature", targets: ["RecordingFeature"]),
        .library(name: "OutboxFeature", targets: ["OutboxFeature"]),
        .library(name: "MemoListFeature", targets: ["MemoListFeature"]),
        .library(name: "MemoDetailFeature", targets: ["MemoDetailFeature"]),
        .library(name: "StatusFeature", targets: ["StatusFeature"]),
        .library(name: "WatchWorkflow", targets: ["WatchWorkflow"]),
        .library(name: "MemoProcessing", targets: ["MemoProcessing"]),
        .library(name: "AudioCapture", targets: ["AudioCapture"]),
        .library(name: "RecordingReminders", targets: ["RecordingReminders"]),
        .library(name: "AudioPlayback", targets: ["AudioPlayback"]),
        .library(name: "WatchPersistence", targets: ["WatchPersistence"]),
        .library(name: "MemoPersistence", targets: ["MemoPersistence"]),
        .library(name: "DeviceSync", targets: ["DeviceSync"]),
        .library(name: "Transcription", targets: ["Transcription"]),
        .library(name: "Summarization", targets: ["Summarization"])
    ],
    targets: [
        .target(name: "VoiceMemoDomain"),
        .target(name: "VoiceMemoInterfaces", dependencies: ["VoiceMemoDomain"]),
        .target(name: "SyncContract", dependencies: ["VoiceMemoDomain"]),
        .target(name: "RecordingFeature", dependencies: ["VoiceMemoDomain", "VoiceMemoInterfaces"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "OutboxFeature", dependencies: ["VoiceMemoDomain", "VoiceMemoInterfaces"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "MemoListFeature", dependencies: ["VoiceMemoDomain", "VoiceMemoInterfaces"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "MemoDetailFeature", dependencies: ["VoiceMemoDomain", "VoiceMemoInterfaces"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "StatusFeature", dependencies: ["VoiceMemoDomain", "VoiceMemoInterfaces"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "WatchWorkflow", dependencies: ["VoiceMemoDomain", "VoiceMemoInterfaces", "SyncContract"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "MemoProcessing", dependencies: ["VoiceMemoDomain", "VoiceMemoInterfaces", "SyncContract"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "AudioCapture", dependencies: ["VoiceMemoDomain", "VoiceMemoInterfaces"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "RecordingReminders", dependencies: ["VoiceMemoDomain", "VoiceMemoInterfaces"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "AudioPlayback", dependencies: ["VoiceMemoDomain", "VoiceMemoInterfaces"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "WatchPersistence", dependencies: ["VoiceMemoDomain", "VoiceMemoInterfaces", "SyncContract"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "MemoPersistence", dependencies: ["VoiceMemoDomain", "VoiceMemoInterfaces"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "DeviceSync", dependencies: ["VoiceMemoDomain", "VoiceMemoInterfaces", "SyncContract"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "Transcription", dependencies: ["VoiceMemoDomain", "VoiceMemoInterfaces"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "Summarization", dependencies: ["VoiceMemoDomain", "VoiceMemoInterfaces"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "VoiceMemoDomainTests", dependencies: ["VoiceMemoDomain"]),
        .testTarget(name: "SyncContractTests", dependencies: ["SyncContract"]),
        .testTarget(name: "WatchWorkflowTests", dependencies: ["WatchWorkflow", "WatchPersistence"]),
        .testTarget(name: "MemoProcessingTests", dependencies: ["MemoProcessing", "MemoPersistence", "Transcription", "Summarization"])
    ]
)
