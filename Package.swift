// swift-tools-version:5.9
import PackageDescription

// FM1Core is the platform-independent brain of Mod-Lab: MIDI parsing/routing,
// transport + clock, Bitwig-style modulators, CV conversion, the project
// model and realtime-safe queues. It has no UIKit/AVFoundation dependency so
// it builds and tests on macOS, iOS and Linux.
//
// The iPad app itself lives in App/ and is generated with XcodeGen
// (see project.yml) because it needs an Xcode app target, entitlements and
// Info.plist keys that SwiftPM cannot express.
let package = Package(
    name: "ModLab",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FM1Core", targets: ["FM1Core"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "FM1Core",
            dependencies: [.product(name: "Atomics", package: "swift-atomics")]
        ),
        .testTarget(name: "FM1CoreTests", dependencies: ["FM1Core"]),
    ]
)
