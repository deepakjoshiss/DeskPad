// swift-tools-version:5.9
import PackageDescription

/// A dummy package whose only purpose is to pin the SwiftFormat used by the
/// "Run SwiftFormat" build phase, so formatting does not drift with whatever
/// happens to be installed on the machine.
let package = Package(
    name: "BuildTools",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/nicklockwood/SwiftFormat", from: "0.62.1"),
    ],
    targets: [.target(name: "BuildTools", path: "")]
)
