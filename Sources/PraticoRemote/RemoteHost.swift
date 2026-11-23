import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import PraticoCore

/// pratico's own SSH to a Linux host (docs/design/remote.md, slice 5): no `ssh` spawned.
/// It runs `docker system dial-stdio` there, as `docker -H ssh://` does, and speaks to the
/// host's daemon through it as the menubar speaks to this Mac's: one request per channel,
/// all on one connection. Keys come from files (OpenSSHKey); host keys must be in
/// `known_hosts` (KnownHosts).
public enum RemoteHost {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// `GET` each path on `target`'s daemon; the responses in order.
    public static func get(_ paths: [String], on target: SSHTarget, timeout: TimeAmount = .seconds(20)) async throws -> [DaemonProbe.Response] {
        let keys = try loadKeys(target)
        let group = MultiThreadedEventLoopGroup.singleton
        let hostKeys = HostKeyCheck(target: target)
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: KeyOffers(user: target.user, keys: keys), serverAuthDelegate: hostKeys)),
                        allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandler(ssh)
                }
            }
        let connection: Channel
        do {
            connection = try await bootstrap.connect(host: target.hostName, port: target.port).get()
        } catch {
            throw Failure(description: "cannot reach \(target.hostName):\(target.port): \(error)")
        }
        let deadline = group.next().scheduleTask(in: timeout) { connection.close(promise: nil) }
        defer {
            deadline.cancel()
            connection.close(promise: nil)
        }
        var responses: [DaemonProbe.Response] = []
        for path in paths {
            let (out, err) = try await exchange(DaemonProbe.requestBytes("GET", path), on: connection)
            if let refusal = hostKeys.refusal { throw refusal }
            guard let r = DaemonProbe.parse(out) else {
                let reason = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure(description: reason.isEmpty ? "\(target.alias): no answer from docker system dial-stdio" : "\(target.alias): \(reason)")
            }
            responses.append(r)
        }
        return responses
    }

    /// The keys pratico can use, or why there is none.
    static func loadKeys(_ target: SSHTarget) throws -> [NIOSSHPrivateKey] {
        var keys: [NIOSSHPrivateKey] = []
        var reasons: [String] = []
        for file in target.identityFiles where FileManager.default.fileExists(atPath: file) {
            do { keys.append(try OpenSSHKey.load(file)) } catch { reasons.append("\(error)") }
        }
        guard !keys.isEmpty else {
            let why = reasons.isEmpty ? "no key in \(target.identityFiles.joined(separator: ", "))" : reasons.joined(separator: "; ")
            throw Failure(description: "no SSH key pratico can use for \(target.alias): \(why)")
        }
        return keys
    }

    /// One exec channel: the request written to `docker system dial-stdio`, its stdout and
    /// stderr read until the daemon closes the connection (the request says `close`).
    static func exchange(_ request: Data, on connection: Channel) async throws -> (Data, Data) {
        let ssh = try await connection.pipeline.handler(type: NIOSSHHandler.self).get()
        let done = connection.eventLoop.makePromise(of: (Data, Data).self)
        let opened = connection.eventLoop.makePromise(of: Channel.self)
        connection.eventLoop.execute {
            ssh.createChannel(opened, channelType: .session) { child, _ in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(DialStdio(request: request, done: done))
                }
            }
        }
        do {
            _ = try await opened.futureResult.get()
        } catch {
            done.fail(error)
            throw Failure(description: "SSH: \(error)")
        }
        return try await done.futureResult.get()
    }
}

/// Runs `docker system dial-stdio` and relays one request through it.
final class DialStdio: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = Never
    typealias OutboundOut = SSHChannelData

    static let maxBytes = 16 << 20
    private let request: Data
    private let done: EventLoopPromise<(Data, Data)>
    private var out = Data()
    private var err = Data()

    init(request: Data, done: EventLoopPromise<(Data, Data)>) {
        self.request = request
        self.done = done
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func channelActive(context: ChannelHandlerContext) {
        let exec = SSHChannelRequestEvent.ExecRequest(command: "docker system dial-stdio", wantReply: true)
        context.triggerUserOutboundEvent(exec, promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: request.count)
        buffer.writeBytes(request)
        context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = message.data else { return }
        if message.type == .channel { out.append(contentsOf: bytes.readableBytesView) } else { err.append(contentsOf: bytes.readableBytesView) }
        if out.count + err.count > Self.maxBytes { context.close(promise: nil) }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let e = event as? ChannelEvent, e == .inputClosed { context.close(promise: nil) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        done.succeed((out, err))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        done.fail(error)
        context.close(promise: nil)
    }
}

/// Offers each key once; the server picks.
final class KeyOffers: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let user: String
    private var keys: [NIOSSHPrivateKey]

    init(user: String, keys: [NIOSSHPrivateKey]) {
        self.user = user
        self.keys = keys
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard availableMethods.contains(.publicKey), !keys.isEmpty else {
            nextChallengePromise.succeed(nil)
            return
        }
        let key = keys.removeFirst()
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: user, serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}

/// `known_hosts` decides; a refusal says why, for the menubar.
final class HostKeyCheck: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let target: SSHTarget
    private(set) var refusal: RemoteHost.Failure?

    init(target: SSHTarget) { self.target = target }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let name = target.port == 22 ? target.hostName : "[\(target.hostName)]:\(target.port)"
        switch KnownHosts.verify(hostKey, host: target.hostName, port: target.port, files: target.knownHostsFiles) {
        case .trusted:
            validationCompletePromise.succeed(())
            return
        case .unknown:
            refusal = .init(description: "\(name) is not in known_hosts: connect once with ssh \(target.alias) to check and trust its key")
        case .changed:
            refusal = .init(description: "\(name)'s host key is not the one in known_hosts: it changed, or someone is in between")
        case .revoked:
            refusal = .init(description: "\(name)'s host key is revoked in known_hosts")
        }
        validationCompletePromise.fail(refusal!)
    }
}
