// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "pratico",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "pratico-daemon", targets: ["pratico-daemon"]),
        .executable(name: "pratico-menubar", targets: ["pratico-menubar"]),
        .executable(name: "pratico-shim", targets: ["pratico-shim"]),
    ],
    dependencies: [
        // Embedded runtime (docs/design/runtime.md); pinned, its API is pre-1.0.
        .package(url: "https://github.com/apple/containerization.git", exact: "0.54.0"),
    ],
    targets: [
        .target(name: "PraticoCore"),
        .target(
            name: "PraticoDaemonKit",
            dependencies: [
                "PraticoCore",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
            ]),
        .executableTarget(name: "pratico-daemon", dependencies: ["PraticoCore", "PraticoDaemonKit"]),
        .executableTarget(name: "pratico-menubar", dependencies: ["PraticoCore"]),
        .executableTarget(name: "pratico-shim", dependencies: ["PraticoDaemonKit"]),
        .executableTarget(name: "pratico-runtime-probe", dependencies: ["PraticoDaemonKit"]),
        .testTarget(name: "PraticoCoreTests", dependencies: ["PraticoCore"]),
        .testTarget(name: "PraticoDaemonKitTests", dependencies: ["PraticoDaemonKit"]),
    ]
)
