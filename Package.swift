// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LexMD",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "LexMD",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/LexMD",
            resources: [.copy("../../Resources/Vendor")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "LexMDTests",
            dependencies: ["LexMD"],
            path: "Tests/LexMDTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
