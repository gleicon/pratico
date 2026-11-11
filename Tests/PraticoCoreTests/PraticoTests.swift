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

/// The job runs only `/bin/ln -s`, never `-f`, with the target as one argument whatever its characters.
@Test func defaultSocketJobOnlyLinksAndScriptsParse() throws {
    let target = "/Users/o'b <&>\nPRATICO_PLIST/.pratico/docker.sock"
    let plist = try #require(PropertyListSerialization.propertyList(
        from: Data(DefaultSocket.launchdPlist(target: target).utf8), format: nil) as? [String: Any])
    #expect(plist["ProgramArguments"] as? [String] == ["/bin/ln", "-s", target, "/var/run/docker.sock"])
    #expect(plist["Label"] as? String == "dev.pratico.socket")
    for script in [DefaultSocket.installScript(target: target), DefaultSocket.removeScript(target: target)] {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/sh")
        p.arguments = ["-n", "-c", script]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }
    #expect(DefaultSocket.installScript(target: target).components(separatedBy: "\n").filter { $0 == "PRATICO_PLIST" }.count == 1)
}
