// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "pratico",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "pratico-daemon", targets: ["pratico-daemon"]),
        .executable(name: "pratico-shim", targets: ["pratico-shim"]),
    ],
    dependencies: [
        // Embedded runtime (docs/design/runtime.md); pinned, its API is pre-1.0.
        // apple/containerization 0.54.0 (baf212e), vendored: pratico's own VM changes it (Vendor/README.md).
        .package(path: "Vendor/containerization"),
        // Already in the graph through containerization; named for pratico's registry client.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.1.2"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        // Linux hosts' registry transport (docs/design/remote.md); already in the graph
        // through containerization.
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.37.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.6"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.21.1"),
        // The menubar's SSH to Linux hosts (docs/design/remote.md, slice 5): no spawned ssh.
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.15.2"),
    ],
    targets: [
        .target(name: "CPratico"),
        .target(name: "PraticoCore", dependencies: ["CPratico"]),
        .target(
            name: "PraticoDaemonKit",
            dependencies: [
                "PraticoCore",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "CloudHypervisor", package: "containerization", condition: .when(platforms: [.linux])),
                .product(name: "AsyncHTTPClient", package: "async-http-client", condition: .when(platforms: [.linux])),
                .product(name: "NIOSSL", package: "swift-nio-ssl", condition: .when(platforms: [.linux])),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "X509", package: "swift-certificates", condition: .when(platforms: [.linux])),
            ]),
        .executableTarget(name: "pratico-daemon", dependencies: ["PraticoCore", "PraticoDaemonKit"]),
        .executableTarget(name: "pratico-shim", dependencies: ["PraticoDaemonKit"]),
        .testTarget(name: "PraticoCoreTests", dependencies: ["PraticoCore"]),
        .testTarget(name: "PraticoDaemonKitTests", dependencies: [
            "PraticoCore", "PraticoDaemonKit", .product(name: "ContainerizationArchive", package: "containerization"),
            .product(name: "ContainerizationOCI", package: "containerization"),
        ]),
    ]
)

// The Mac app's own targets; a Linux host (docs/design/remote.md) builds the daemon and shim only.
#if os(macOS)
package.products.append(.executable(name: "pratico-menubar", targets: ["pratico-menubar"]))
package.targets += [
    // pratico's own SSH to Linux hosts, for the menubar (docs/design/remote.md, slice 5).
    .target(name: "PraticoRemote", dependencies: [
        "PraticoCore",
        .product(name: "NIOSSH", package: "swift-nio-ssh"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "Crypto", package: "swift-crypto"),
    ]),
    .testTarget(name: "PraticoRemoteTests", dependencies: ["PraticoRemote", .product(name: "NIOSSH", package: "swift-nio-ssh")]),
    .executableTarget(name: "pratico-menubar", dependencies: ["PraticoCore", "PraticoRemote"]),
    .executableTarget(name: "pratico-runtime-probe", dependencies: ["PraticoDaemonKit"]),
]
#endif
