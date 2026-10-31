// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TimeTrack",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "timetrack", targets: ["timetrack"]),
        .executable(name: "TimeTrackBar", targets: ["TimeTrackBar"]),
    ],
    targets: [
        .target(
            name: "TimeTrackCore",
            path: "Sources/TimeTrackCore"
        ),
        .executableTarget(
            name: "timetrack",
            dependencies: ["TimeTrackCore"],
            path: "Sources/timetrack"
        ),
        .executableTarget(
            name: "TimeTrackBar",
            dependencies: ["TimeTrackCore"],
            path: "Sources/TimeTrackBar",
            exclude: ["Info.plist"]
        ),
    ]
)
