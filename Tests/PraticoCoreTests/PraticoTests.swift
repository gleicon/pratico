import Foundation
import Testing

@testable import PraticoCore

@Test func socketLivesUnderPraticoHome() {
    let user = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
    let socket = Pratico.socketPath(home: Pratico.home(for: user))
    #expect(socket.path == "/Users/someone/.pratico/docker.sock")
}
