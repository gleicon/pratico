import Foundation
import Testing

@testable import PraticoCore

@Test func socketLivesUnderPraticoHome() {
    let user = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
    let socket = Pratico.socketPath(home: Pratico.home(for: user))
    #expect(socket.path == "/Users/someone/.pratico/docker.sock")
}

@Test func defaultSocketLinkIsClaimedOnlyWhenFreeAndReleasedOnlyIfOurs() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "pratico-link-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let link = dir.appending(path: "docker.sock").path
    let ours = "/Users/a/.pratico/docker.sock"

    #expect(DefaultSocket.state(link: link, target: ours) == .absent)
    #expect(DefaultSocket.claim(link: link, target: ours) == .ours)
    #expect(DefaultSocket.claim(link: link, target: ours) == .ours)
    DefaultSocket.release(link: link, target: ours)
    #expect(DefaultSocket.state(link: link, target: ours) == .absent)

    let docker = "/Users/a/.docker/run/docker.sock"
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: docker)
    #expect(DefaultSocket.claim(link: link, target: ours) == .other(docker))
    DefaultSocket.release(link: link, target: ours)
    #expect(DefaultSocket.state(link: link, target: ours) == .other(docker))

    try FileManager.default.removeItem(atPath: link)
    FileManager.default.createFile(atPath: link, contents: nil)
    #expect(DefaultSocket.claim(link: link, target: ours) == .other("a file that is not a link"))
}
