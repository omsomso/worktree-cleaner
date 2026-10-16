// swift-tools-version: 6.0
import PackageDescription

// Worktree Cleaner: finds git worktrees whose work is already merged and removes the ones you pick.
let package = Package(
    name: "WorktreeCleaner",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "WorktreeCore",
            path: "Sources/WorktreeCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "WorktreeCleaner",
            dependencies: ["WorktreeCore"],
            path: "Sources/WorktreeCleaner",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WorktreeCoreTests",
            dependencies: ["WorktreeCore"],
            path: "Tests/WorktreeCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
