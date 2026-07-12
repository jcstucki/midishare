// swift-tools-version:5.0
import PackageDescription

let package = Package(
    name: "MIDIShare",
    platforms: [.macOS(.v10_14)],
    targets: [
        .target(name: "MIDIShareServer", dependencies: [], path: "Sources/MIDIShareServer"),
        .target(name: "MIDIShareClient", dependencies: [], path: "Sources/MIDIShareClient"),
    ]
)
