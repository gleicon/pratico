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
        var Leftover: Int64
        var Bytes: Int64
        var isEmpty: Bool { Containers.isEmpty && Images.isEmpty && Leftover == 0 }
    }
    struct Cleanups: Decodable, Equatable {
        var Containers: Plan
        var Images: Plan
        var Both: Plan

        func plan(containers: Bool, images: Bool) -> Plan { containers && images ? Both : containers ? Containers : Images }
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
                Text("Guest init, shared by all: \(bytes(d.Runtime))")
                Text("Scan data: \(bytes(d.Scans))")
                Menu("Largest") {
                    ForEach(largest(d), id: \.self) { Text($0) }
                }
                Divider()
                cleanupButton(d, "Remove Stopped Containers", containers: true, images: false)
                cleanupButton(d, "Remove Unused Images", containers: false, images: true)
                cleanupButton(d, "Clean Up Both", containers: true, images: true)
            }
        }
    }

    private func cleanupButton(_ d: DiskUsage, _ title: String, containers: Bool, images: Bool) -> some View {
        let c = d.Cleanup.plan(containers: containers, images: images)
        return Button("\(title) (\(bytes(c.Bytes)))…") { daemon.cleanUp(containers: containers, images: images) }
            .disabled(c.isEmpty)
    }

    private func largest(_ d: DiskUsage) -> [String] {
        let images = d.Images.Items.map { (size: $0.Size, line: "\(bytes($0.Size))  image \($0.Name)\($0.Containers == 0 ? " (unused)" : "")") }
        let containers = d.Containers.Items.map { (size: $0.Size + $0.Logs, line: "\(bytes($0.Size + $0.Logs))  container \($0.Name)\($0.Running ? "" : " (stopped)")") }
        return (images + containers).sorted { $0.size > $1.size }.prefix(8).map(\.line)
    }
}
