import Foundation
import Testing

@testable import PraticoCore

/// A docker config directory as the CLI leaves it: two contexts, logins, a current context.
private func dockerDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "pratico-contexts-\(UUID().uuidString)", directoryHint: .isDirectory)
    for (hash, name, host) in [("a1", "pratico", "unix:///Users/me/.pratico/docker.sock"), ("b2", "vps", "ssh://me@vps.example:2222")] {
        let meta = dir.appending(path: "contexts/meta/\(hash)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try Data(#"{"Name":"\#(name)","Metadata":{},"Endpoints":{"docker":{"Host":"\#(host)","SkipTLSVerify":false}}}"#.utf8)
            .write(to: meta.appending(path: "meta.json"))
    }
    try Data(#"{"auths":{"ghcr.io":{"auth":"c2VjcmV0"}},"currentContext":"pratico","credsStore":"osxkeychain"}"#.utf8)
        .write(to: dir.appending(path: "config.json"))
    return dir
}

@Test func contextsListDefaultFirstThenByName() throws {
    let c = DockerContexts(directory: try dockerDir())
    #expect(c.list().map(\.name) == ["default", "pratico", "vps"])
    #expect(c.list().last?.sshTarget == "me@vps.example:2222")
    #expect(c.list()[1].sshTarget == nil)
    #expect(c.current() == "pratico")
}

@Test func useWritesOnlyCurrentContextAndKeepsLogins() throws {
    let dir = try dockerDir()
    let c = DockerContexts(directory: dir)
    try c.use("vps")
    #expect(c.current() == "vps")
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: "config.json"))) as? [String: Any]
    #expect((json?["auths"] as? [String: Any])?["ghcr.io"] != nil)
    #expect(json?["credsStore"] as? String == "osxkeychain")
    let mode = try FileManager.default.attributesOfItem(atPath: dir.appending(path: "config.json").path)[.posixPermissions] as? Int
    #expect(mode == 0o600)

    try c.use("default")
    #expect(c.current() == "default")
    #expect(json?.keys.contains("auths") == true)
}

@Test func useRefusesUnknownContextsAndNeverOverwritesABadConfig() throws {
    let dir = try dockerDir()
    let c = DockerContexts(directory: dir)
    #expect(throws: DockerContexts.ContextError.self) { try c.use("nope") }
    try Data("[1,2]".utf8).write(to: dir.appending(path: "config.json"))
    #expect(throws: DockerContexts.ContextError.self) { try c.use("vps") }
    #expect(try String(contentsOf: dir.appending(path: "config.json"), encoding: .utf8) == "[1,2]")
}

@Test func useKeepsASymlinkedConfigALinkAndItsTarget0600() throws {
    let dir = try dockerDir()
    let real = dir.appending(path: "dotfiles-config.json")
    try FileManager.default.moveItem(at: dir.appending(path: "config.json"), to: real)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: real.path)
    try FileManager.default.createSymbolicLink(at: dir.appending(path: "config.json"), withDestinationURL: real)
    try DockerContexts(directory: dir).use("vps")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dir.appending(path: "config.json").path) == real.path)
    #expect(try String(contentsOf: real, encoding: .utf8).contains("\"currentContext\" : \"vps\""))
    #expect(try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.contains(".pratico-") })
}

@Test func hostKeysKeepOnlyPathsInA0600File() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "pratico-hostkeys-\(UUID().uuidString)", directoryHint: .isDirectory)
    let keys = HostKeys(home: home)
    #expect(keys.identity(for: "vps") == nil)
    try keys.setIdentity("/Users/me/.ssh/id_ed25519_vps", for: "vps")
    try keys.setIdentity("/Users/me/.ssh/other", for: "box")
    #expect(keys.identity(for: "vps") == "/Users/me/.ssh/id_ed25519_vps")
    #expect(try FileManager.default.attributesOfItem(atPath: keys.file.path)[.posixPermissions] as? Int == 0o600)
    try keys.setIdentity(nil, for: "vps")
    #expect(keys.identity(for: "vps") == nil && keys.identity(for: "box") == "/Users/me/.ssh/other")
}
