import AppKit
import PraticoCore
import SwiftUI

/// `GET /pratico/disk`: allocated bytes, a shared layer counted once.
struct DiskUsage: Decodable, Equatable {
    struct Image: Decodable, Equatable {
        var Id: String
        var Name: String
        var Size: Int64
        var Containers: Int
    }
    struct Container: Decodable, Equatable {
        var Id: String
        var Name: String
        var Running: Bool
        var Size: Int64
        var Logs: Int64
    }
    struct ImageGroup: Decodable, Equatable {
        var Size: Int64
        var Unused: Int64
        var Unreferenced: Int64
        var Items: [Image]
    }
    struct ContainerGroup: Decodable, Equatable {
        var Running: Int64
        var Stopped: Int64
        var Logs: Int64
        var Items: [Container]
    }
    var Total: Int64
    var Free: Int64
    var Images: ImageGroup
    var Containers: ContainerGroup
    struct VolumeGroup: Decodable, Equatable {
        struct Volume: Decodable, Equatable {
            var Name: String
            var Size: Int64
            var Containers: Int
            var Anonymous: Bool
        }
        var Size: Int64
        var Unused: Int64
        var Items: [Volume]
    }
    var Volumes: VolumeGroup
    var Runtime: Int64
    var Scans: Int64

    var Cleanup: Cleanups

    var stopped: [Container] { Containers.Items.filter { !$0.Running } }

    /// What a cleanup removes and frees, worked out by the daemon with the rule its prune
    /// applies: the button, the confirmation, and the result all read the same plan.
    struct Plan: Decodable, Equatable {
        struct Item: Decodable, Equatable {
            var Id: String
            var Name: String
            var Size: Int64
        }
        var Containers: [Item]
        var Images: [Item]
        var Volumes: [Item]
        var Leftover: Int64
        var Bytes: Int64
        var isEmpty: Bool { Containers.isEmpty && Images.isEmpty && Volumes.isEmpty && Leftover == 0 }
    }
    struct Cleanups: Decodable, Equatable {
        var Containers: Plan
        var Images: Plan
        var Both: Plan
        var Volumes: Plan

        subscript(kind: CleanupKind) -> Plan {
            switch kind {
            case .containers: Containers
            case .images: Images
            case .both: Both
            case .volumes: Volumes
            }
        }
    }
}

/// The Disk menu's cleanups and the Docker prune calls behind each, in the order they run:
/// containers first, so the images they held become unused.
enum CleanupKind: CaseIterable {
    case containers, images, both, volumes

    var title: String {
        switch self {
        case .containers: "Remove Stopped Containers"
        case .images: "Remove Unused Images"
        case .both: "Clean Up Both"
        case .volumes: "Remove Unused Volumes"
        }
    }

    var prunes: [String] {
        let containers = "/containers/prune"
        let images = "/images/prune?filters=%7B%22dangling%22%3A%5B%22false%22%5D%7D"  // {"dangling":["false"]}
        switch self {
        case .containers: return [containers]
        case .images: return [images]
        case .both: return [containers, images]
        case .volumes: return ["/volumes/prune?filters=%7B%22all%22%3A%5B%22true%22%5D%7D"]  // {"all":["true"]}
        }
    }

    /// What the confirmation says stays, or is lost.
    var note: String {
        switch self {
        case .volumes: "The data in these volumes is deleted and cannot be recovered. Volumes any container mounts, running or stopped, are kept."
        default: "Running containers and the images they use are kept."
        }
    }
}

func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

/// Space used, by kind and running or not, and cleanup that says what it frees first.
/// Running containers and the images they use are never touched.
struct DiskMenu: View {
    let daemon: DaemonController

    var body: some View {
        if let d = daemon.disk {
            Menu("Disk: \(bytes(d.Total)) used") {
                Text("\(bytes(d.Free)) free on this Mac")
                Divider()
                // Each line is its own slice; together they make the total above.
                Text("Images: \(bytes(d.Images.Size - d.Images.Unreferenced))  (\(bytes(d.Images.Unused)) unused)")
                if d.Images.Unreferenced > 0 { Text("Leftover image data: \(bytes(d.Images.Unreferenced))") }
                Text("Running containers: \(bytes(d.Containers.Running))  (\(d.Containers.Items.count - d.stopped.count))")
                Text("Stopped containers: \(bytes(d.Containers.Stopped))  (\(d.stopped.count))")
                Text("Container logs: \(bytes(d.Containers.Logs))")
                Text("Volumes: \(bytes(d.Volumes.Size))  (\(d.Volumes.Items.count), \(bytes(d.Volumes.Unused)) unused)")
                Text("Guest init, shared by all: \(bytes(d.Runtime))")
                Text("Scan data: \(bytes(d.Scans))")
                Menu("Largest") {
                    ForEach(largest(d), id: \.self) { Text($0) }
                }
                Divider()
                ForEach(CleanupKind.allCases, id: \.self) { kind in
                    if kind == .volumes { Divider() }  // data, not rebuildable: set apart
                    let plan = d.Cleanup[kind]
                    Button("\(kind.title) (\(bytes(plan.Bytes)))…") { daemon.cleanUp(kind) }.disabled(plan.isEmpty)
                }
            }
        }
    }

    private func largest(_ d: DiskUsage) -> [String] {
        let images = d.Images.Items.map { (size: $0.Size, line: "\(bytes($0.Size))  image \($0.Name)\($0.Containers == 0 ? " (unused)" : "")") }
        let containers = d.Containers.Items.map { (size: $0.Size + $0.Logs, line: "\(bytes($0.Size + $0.Logs))  container \($0.Name)\($0.Running ? "" : " (stopped)")") }
        let volumes = d.Volumes.Items.map { (size: $0.Size, line: "\(bytes($0.Size))  volume \($0.Anonymous ? String($0.Name.prefix(12)) : $0.Name)\($0.Containers == 0 ? " (unused)" : "")") }
        return (images + containers + volumes).sorted { $0.size > $1.size }.prefix(8).map(\.line)
    }
}
