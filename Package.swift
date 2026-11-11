// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "pratico",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "pratico-daemon", targets: ["pratico-daemon"]),
        .executable(name: "pratico-menubar", targets: ["pratico-menubar"]),
        .executable(name: "pratico-shim", targets: ["pratico-shim"]),
        .executable(name: "pratico-socket-link", targets: ["pratico-socket-link"]),
    ],
    dependencies: [
        // Embedded runtime (docs/design/runtime.md); pinned, its API is pre-1.0.
        .package(url: "https://github.com/apple/containerization.git", exact: "0.54.0"),
        // Already in the graph through containerization; named for pratico's registry client.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
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
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]),
        .executableTarget(name: "pratico-daemon", dependencies: ["PraticoCore", "PraticoDaemonKit"]),
        .executableTarget(name: "pratico-menubar", dependencies: ["PraticoCore"]),
        .executableTarget(name: "pratico-shim", dependencies: ["PraticoDaemonKit"]),
        .executableTarget(name: "pratico-socket-link", dependencies: ["PraticoCore"]),
        .executableTarget(name: "pratico-runtime-probe", dependencies: ["PraticoDaemonKit"]),
        .testTarget(name: "PraticoCoreTests", dependencies: ["PraticoCore"]),
        .testTarget(name: "PraticoDaemonKitTests", dependencies: ["PraticoCore", "PraticoDaemonKit"]),
    ]
)
