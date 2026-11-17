//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Modified by the Pratico project (2026-11-16): the agent is polled every 2 ms, not
// 20 ms, and each connection attempt and the whole wait are bounded, so a guest that
// halts at boot fails the start instead of hanging it (Vendor/README.md).
//===----------------------------------------------------------------------===//

#if os(macOS)
import Foundation
import Logging
import Virtualization
import ContainerizationError
import Synchronization

extension VZVirtualMachine {
    nonisolated func connect(queue: DispatchQueue, port: UInt32) async throws -> VZVirtioSocketConnection {
        try await withCheckedThrowingContinuation { cont in
            queue.sync {
                guard let vsock = self.socketDevices[0] as? VZVirtioSocketDevice else {
                    let error = ContainerizationError(.invalidArgument, message: "no vsock device")
                    cont.resume(throwing: error)
                    return
                }
                vsock.connect(toPort: port) { result in
                    switch result {
                    case .success(let conn):
                        // `conn` isn't used concurrently.
                        nonisolated(unsafe) let conn = conn
                        cont.resume(returning: conn)
                    case .failure(let error):
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    func listen(queue: DispatchQueue, port: UInt32, listener: VZVirtioSocketListener) throws {
        try queue.sync {
            guard let vsock = self.socketDevices[0] as? VZVirtioSocketDevice else {
                throw ContainerizationError(.invalidArgument, message: "no vsock device")
            }
            vsock.setSocketListener(listener, forPort: port)
        }
    }

    func removeListener(queue: DispatchQueue, port: UInt32) throws {
        try queue.sync {
            guard let vsock = self.socketDevices[0] as? VZVirtioSocketDevice else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no vsock device to remove"
                )
            }
            vsock.removeSocketListener(forPort: port)
        }
    }

    func start(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                self.start { result in
                    if case .failure(let error) = result {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume()
                }
            }
        }
    }

    func stop(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                self.stop { error in
                    if let error {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume()
                }
            }
        }
    }

    func pause(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                self.pause { result in
                    if case .failure(let error) = result {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume()
                }
            }
        }
    }

    func resume(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                self.resume { result in
                    if case .failure(let error) = result {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume()
                }
            }
        }
    }
}

extension VZVirtualMachine {
    func waitForAgent(queue: DispatchQueue) async throws -> FileHandle {
        let deadline = ContinuousClock.now + .seconds(10)
        let attemptTimeout: Duration = .seconds(1)
        let agentConnectionSleepDuration: Duration = .milliseconds(2)
        let attemptsMax = 5000  // the deadline ends it first; this bounds the loop

        for _ in 0..<attemptsMax where ContinuousClock.now < deadline {
            do {
                return try await self.connect(queue: queue, port: Vminitd.port, timeout: attemptTimeout).dupHandle()
            } catch {
                try await Task.sleep(for: agentConnectionSleepDuration)
            }
        }
        throw ContainerizationError(.timeout, message: "the guest agent did not answer within 10 s (did the guest kernel or init fail at boot?)")
    }

    /// `connect(queue:port:)` that gives up after `timeout`: Virtualization calls back
    /// only when the guest answers, and a guest that halted never does. A connection
    /// that arrives after the timeout is closed.
    nonisolated func connect(queue: DispatchQueue, port: UInt32, timeout: Duration) async throws -> VZVirtioSocketConnection {
        let resumed = Mutex(false)
        return try await withCheckedThrowingContinuation { cont in
            let claim = { resumed.withLock { done in defer { done = true }; return !done } }
            queue.sync {
                guard let vsock = self.socketDevices[0] as? VZVirtioSocketDevice else {
                    if claim() { cont.resume(throwing: ContainerizationError(.invalidArgument, message: "no vsock device")) }
                    return
                }
                vsock.connect(toPort: port) { result in
                    switch result {
                    case .success(let conn):
                        // `conn` isn't used concurrently.
                        nonisolated(unsafe) let conn = conn
                        if claim() { cont.resume(returning: conn) } else { conn.close() }
                    case .failure(let error):
                        if claim() { cont.resume(throwing: error) }
                    }
                }
            }
            let ms = Int(timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
            queue.asyncAfter(deadline: .now() + .milliseconds(ms)) {
                if claim() { cont.resume(throwing: ContainerizationError(.timeout, message: "vsock connect to port \(port) timed out")) }
            }
        }
    }
}

extension VZVirtioSocketConnection {
    func dupHandle() throws -> FileHandle {
        let fd = dup(self.fileDescriptor)
        if fd == -1 {
            throw POSIXError.fromErrno()
        }
        self.close()
        return FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    }
}

#endif
