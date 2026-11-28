import Foundation
import NIOSSH
import Testing

@testable import PraticoRemote

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "pratico-remote-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// The real `ssh-keygen`, so the files are exactly what users have.
private func keygen(_ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/ssh-keygen")
    p.arguments = ["-q"] + args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    #expect(p.terminationStatus == 0, "ssh-keygen \(args.joined(separator: " "))")
}

private func publicKey(_ path: String) throws -> NIOSSHPublicKey {
    let line = try String(contentsOfFile: path + ".pub", encoding: .utf8).split(separator: " ")
    return try NIOSSHPublicKey(openSSHPublicKey: "\(line[0]) \(line[1])")
}

@Test(arguments: [["-t", "ed25519"], ["-t", "ecdsa", "-b", "256"], ["-t", "ecdsa", "-b", "384"], ["-t", "ecdsa", "-b", "521"]])
func keyFilesLoadAsTheKeysSshKeygenMade(_ type: [String]) throws {
    let file = try tempDir().appending(path: "id").path
    try keygen(type + ["-N", "", "-f", file])
    #expect(try OpenSSHKey.load(file).publicKey == publicKey(file))
}

@Test func keysPraticoCannotUseSayWhy() throws {
    let dir = try tempDir()
    try keygen(["-t", "ed25519", "-N", "secret", "-f", dir.appending(path: "locked").path])
    try keygen(["-t", "rsa", "-b", "2048", "-N", "", "-f", dir.appending(path: "rsa").path])
    for (name, says) in [("locked", "passphrase"), ("rsa", "RSA")] {
        do {
            _ = try OpenSSHKey.load(dir.appending(path: name).path)
            Issue.record("\(name) loaded")
        } catch {
            #expect("\(error)".contains(says))
        }
    }
}

@Test func knownHostsTrustsOnlyTheKeyItNames() throws {
    let dir = try tempDir()
    let a = dir.appending(path: "a").path, b = dir.appending(path: "b").path
    try keygen(["-t", "ed25519", "-N", "", "-f", a])
    try keygen(["-t", "ed25519", "-N", "", "-f", b])
    let keyA = try String(contentsOfFile: a + ".pub", encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")
    let keyB = try String(contentsOfFile: b + ".pub", encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")
    let file = dir.appending(path: "known_hosts")
    try "vps.example \(keyA)\n[box.example]:2222 \(keyA)\n*.lab.example,!bad.lab.example \(keyA)\n@revoked old.example \(keyB)\nold.example \(keyA)\n"
        .write(to: file, atomically: true, encoding: .utf8)
    let files = [file.path]
    let ka = try publicKey(a), kb = try publicKey(b)
    #expect(KnownHosts.verify(ka, host: "vps.example", port: 22, files: files) == .trusted)
    #expect(KnownHosts.verify(kb, host: "vps.example", port: 22, files: files) == .changed)
    #expect(KnownHosts.verify(ka, host: "box.example", port: 2222, files: files) == .trusted)
    #expect(KnownHosts.verify(ka, host: "box.example", port: 22, files: files) == .unknown)
    #expect(KnownHosts.verify(ka, host: "one.lab.example", port: 22, files: files) == .trusted)
    #expect(KnownHosts.verify(ka, host: "bad.lab.example", port: 22, files: files) == .unknown)
    #expect(KnownHosts.verify(kb, host: "old.example", port: 22, files: files) == .revoked)
    #expect(KnownHosts.verify(ka, host: "nowhere.example", port: 22, files: files) == .unknown)

    // Hashed by ssh-keygen itself, as HashKnownHosts writes them.
    try keygen(["-H", "-f", file.path])
    #expect(try String(contentsOf: file, encoding: .utf8).contains("|1|"))
    #expect(KnownHosts.verify(ka, host: "vps.example", port: 22, files: files) == .trusted)
    #expect(KnownHosts.verify(ka, host: "box.example", port: 2222, files: files) == .trusted)
    #expect(KnownHosts.verify(kb, host: "vps.example", port: 22, files: files) == .changed)
}

@Test func sshConfigResolvesAsSshDoes() throws {
    let home = try tempDir()
    try FileManager.default.createDirectory(at: home.appending(path: ".ssh/conf.d"), withIntermediateDirectories: true)
    try """
        Include conf.d/*.conf
        Host vps
            HostName 203.0.113.7
            User deploy
            IdentityFile ~/.ssh/vps_key
        Host *
            User fallback
            IdentityFile %d/.ssh/id_ed25519
            Port 22
        """.write(to: home.appending(path: ".ssh/config"), atomically: true, encoding: .utf8)
    try """
        Host vps
            Port 2222
        Host *.lab !bad.lab
            ProxyJump bastion
        """.write(to: home.appending(path: ".ssh/conf.d/extra.conf"), atomically: true, encoding: .utf8)

    let vps = try SSHTarget.resolve("vps", home: home)
    #expect(vps.hostName == "203.0.113.7")
    #expect(vps.port == 2222)  // the include comes first: first value wins
    #expect(vps.user == "deploy")
    #expect(vps.identityFiles == ["\(home.path)/.ssh/vps_key", "\(home.path)/.ssh/id_ed25519"])

    let explicit = try SSHTarget.resolve("me@vps:2200", home: home)
    #expect(explicit.user == "me" && explicit.port == 2200)
    #expect(try SSHTarget.resolve("other", home: home).user == "fallback")
    #expect(throws: SSHTarget.Unsupported.self) { try SSHTarget.resolve("one.lab", home: home) }
    #expect(try SSHTarget.resolve("bad.lab", home: home).hostName == "bad.lab")
}

/// Against a real sshd and pratico's Linux service: e2e/testhost.sh sets these and runs it.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PRATICO_REMOTE_TEST_TARGET"] != nil))
func remoteHostAnswersOverPraticosOwnSSH() async throws {
    let env = ProcessInfo.processInfo.environment
    let target = try SSHTarget.resolve(env["PRATICO_REMOTE_TEST_TARGET"]!, config: env["PRATICO_REMOTE_TEST_CONFIG"].map { URL(filePath: $0) })
    let responses = try await RemoteHost.get(["/version", "/pratico/status"], on: target)
    #expect(responses.map(\.status) == [200, 200])
    let version = try JSONSerialization.jsonObject(with: responses[0].body) as? [String: Any]
    #expect(version?["Os"] as? String == "linux")

    // Each way it fails says which, for the menubar to offer what fixes it.
    let dir = try tempDir()
    try keygen(["-t", "ed25519", "-N", "", "-f", dir.appending(path: "other").path])
    let other = try String(contentsOfFile: dir.appending(path: "other.pub").path, encoding: .utf8).split(separator: " ")
    let name = target.port == 22 ? target.hostName : "[\(target.hostName)]:\(target.port)"
    try "".write(to: dir.appending(path: "empty"), atomically: true, encoding: .utf8)
    try "\(name) \(other[0]) \(other[1])\n".write(to: dir.appending(path: "changed"), atomically: true, encoding: .utf8)
    var unknown = target, changed = target, keyless = target, closed = target
    unknown.knownHostsFiles = [dir.appending(path: "empty").path]
    changed.knownHostsFiles = [dir.appending(path: "changed").path]
    keyless.identityFiles = [dir.appending(path: "none").path]
    closed.hostName = "127.0.0.1"
    closed.port = 1
    for (t, kind) in [(unknown, RemoteHost.Failure.Kind.unknownHostKey), (changed, .changedHostKey), (keyless, .noUsableKey), (closed, .unreachable)] {
        do {
            _ = try await RemoteHost.get(["/version"], on: t)
            Issue.record("\(kind): answered")
        } catch let failure as RemoteHost.Failure {
            #expect(failure.kind == kind, "\(failure)")
        }
    }
}
