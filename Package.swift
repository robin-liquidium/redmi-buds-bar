// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "RedmiBudsBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "RedmiBudsBar", targets: ["RedmiBudsBar"]), .executable(name: "budsctl", targets: ["BudsCLI"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")],
    targets: [
        .target(name: "BudsCore", linkerSettings: [.linkedFramework("IOBluetooth")]),
        .target(name: "MediaCore"),
        .executableTarget(name: "RedmiBudsBar", dependencies: ["BudsCore", "MediaCore", .product(name: "Sparkle", package: "Sparkle")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "BudsCLI", dependencies: ["BudsCore"]),
        .testTarget(name: "BudsCoreTests", dependencies: ["BudsCore"]),
        .testTarget(name: "MediaCoreTests", dependencies: ["MediaCore"])
    ],
    swiftLanguageModes: [.v5]
)
