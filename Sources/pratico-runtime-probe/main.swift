// Development check for the embedded runtime: boots one container and prints its
// output. Not shipped in the app. Usage: make probe  (signs with the virtualization
// entitlement, which Virtualization.framework requires).
import Foundation
import PraticoDaemonKit

let args = Array(CommandLine.arguments.dropFirst())
let image = args.first ?? "docker.io/library/alpine:latest"
let command = args.count > 1 ? Array(args.dropFirst()) : ["uname", "-a"]
let home = URL(filePath: ProcessInfo.processInfo.environment["PRATICO_HOME"] ?? NSHomeDirectory() + "/.pratico")

let started = Date()
do {
    let runtime = try await EmbeddedRuntime.open(home: home)
    let opened = Date()
    let (status, output) = try await runtime.run(image: image, arguments: command)
    FileHandle.standardOutput.write(output)
    print(String(format: "exit %d · open %.2fs · run %.2fs", status, opened.timeIntervalSince(started), Date().timeIntervalSince(opened)))
    exit(status)
} catch {
    FileHandle.standardError.write(Data("probe failed: \(error)\n".utf8))
    exit(1)
}
