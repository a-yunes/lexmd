// swift-tools-version: 6.2
import PackageDescription

/// `scripts/build-app.sh` sets this to a folder for App Intents metadata. The release build then
/// emits the compile-time values that `appintentsmetadataprocessor` reads.
let appIntentsFolder = Context.environment["LEXMD_APPINTENTS_DIR"]
let appSwiftSettings: [SwiftSetting] = appIntentsFolder.map { folder in
    [.unsafeFlags([
        "-emit-const-values-path", folder + "/LexMD.swiftconstvalues",
        "-Xfrontend", "-const-gather-protocols-file", "-Xfrontend", folder + "/protocols.json",
    ], .when(configuration: .release))]
} ?? []

let package = Package(
    name: "LexMD",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0"),
    ],
    targets: [
        // Markdown to HTML and the preview's styles, shared by the app and the Quick Look extension.
        .target(
            name: "LexMDRendering",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")],
            path: "Sources/LexMDRendering"
        ),
        .executableTarget(
            name: "LexMD",
            dependencies: [
                "LexMDRendering",
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/LexMD",
            resources: [.copy("../../Resources/Vendor"), .copy("../../Resources/Help"), .copy("../../Resources/Demo")],
            swiftSettings: appSwiftSettings,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // The Quick Look preview extension; `scripts/build-app.sh` wraps it in an .appex bundle.
        .executableTarget(
            name: "LexMDQuickLook",
            dependencies: ["LexMDRendering"],
            path: "Sources/LexMDQuickLook",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [
                .linkedFramework("QuickLookUI"),
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-Xlinker", "-application_extension"]),
            ]
        ),
        .testTarget(
            name: "LexMDTests",
            dependencies: ["LexMD", "LexMDRendering"],
            path: "Tests/LexMDTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
