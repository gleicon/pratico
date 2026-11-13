import Foundation
import Testing

@testable import PraticoCore

@Test func socketLivesUnderPraticoHome() {
    let user = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
    let socket = Pratico.socketPath(home: Pratico.home(for: user))
    #expect(socket.path == "/Users/someone/.pratico/docker.sock")
}

@Test func defaultSocketStateTellsOursFromOthers() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "pratico-link-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let link = dir.appending(path: "docker.sock").path
    let ours = "/Users/a/.pratico/docker.sock"

    #expect(DefaultSocket.state(link: link, target: ours) == .absent)
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: ours)
    #expect(DefaultSocket.state(link: link, target: ours) == .ours)
    try FileManager.default.removeItem(atPath: link)
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/Users/a/.docker/run/docker.sock")
    #expect(DefaultSocket.state(link: link, target: ours) == .other("/Users/a/.docker/run/docker.sock"))
    try FileManager.default.removeItem(atPath: link)
    FileManager.default.createFile(atPath: link, contents: nil)
    #expect(DefaultSocket.state(link: link, target: ours) == .other("a file that is not a link"))
}

/// The commands the menubar shows parse, and the boot job runs only `/bin/ln -s`, never
/// `-f`, with the target as one argument whatever its characters.
@Test func defaultSocketJobOnlyLinksAndScriptsParse() throws {
    let target = "/Users/o'b <&>\nPRATICO_PLIST/.pratico/docker.sock"
    let plist = try #require(PropertyListSerialization.propertyList(
        from: Data(DefaultSocket.launchdPlist(target: target).utf8), format: nil) as? [String: Any])
    #expect(plist["ProgramArguments"] as? [String] == ["/bin/ln", "-s", target, "/var/run/docker.sock"])
    #expect(plist["Label"] as? String == "dev.pratico.socket")
    let commands = [DefaultSocket.linkCommand, DefaultSocket.persistCommands, DefaultSocket.removeCommands]
    for script in commands {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/sh")
        p.arguments = ["-n", "-c", script]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }
    #expect(DefaultSocket.persistCommands.components(separatedBy: "\n").filter { $0 == "PRATICO_PLIST" }.count == 1)
    #expect(DefaultSocket.linkCommand == #"sudo ln -s "$HOME/.pratico/docker.sock" /var/run/docker.sock"#)
}

/// The startup job's plist gets the user's own home from their shell, as an absolute path.
@Test func persistCommandsWriteTheUsersHomeIntoThePlist() throws {
    let out = FileManager.default.temporaryDirectory.appending(path: "pratico-persist-\(UUID().uuidString.prefix(8)).plist")
    defer { try? FileManager.default.removeItem(at: out) }
    let script = DefaultSocket.persistCommands
        .replacingOccurrences(of: "sudo tee \(DefaultSocket.plistPath) >/dev/null", with: "cat > '\(out.path)'")
        .split(separator: "\n").filter { !$0.contains("launchctl") }.joined(separator: "\n")
    let p = Process()
    p.executableURL = URL(filePath: "/bin/sh")
    p.arguments = ["-c", script]
    p.environment = ["HOME": "/Users/someone"]
    try p.run()
    p.waitUntilExit()
    let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: out), format: nil) as? [String: Any])
    #expect(plist["ProgramArguments"] as? [String] == ["/bin/ln", "-s", "/Users/someone/.pratico/docker.sock", "/var/run/docker.sock"])
}
