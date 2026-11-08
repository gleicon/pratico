// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "pratico",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "pratico-daemon", targets: ["pratico-daemon"]),
        .executable(name: "pratico-menubar", targets: ["pratico-menubar"]),
    ],
    targets: [
        .target(name: "PraticoCore"),
        .target(name: "PraticoDaemonKit", dependencies: ["PraticoCore"]),
        .executableTarget(name: "pratico-daemon", dependencies: ["PraticoCore", "PraticoDaemonKit"]),
        .executableTarget(name: "pratico-menubar", dependencies: ["PraticoCore"]),
        .testTarget(name: "PraticoCoreTests", dependencies: ["PraticoCore"]),
        .testTarget(name: "PraticoDaemonKitTests", dependencies: ["PraticoDaemonKit"]),
    ]
)
