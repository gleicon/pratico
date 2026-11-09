// pratico-shim: runs one container's VM (docs/design/runtime.md). Started by
// pratico-daemon in its own session; usage: pratico-shim <container-dir>
import Foundation
import PraticoDaemonKit

signal(SIGPIPE, SIG_IGN)
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: pratico-shim <container-dir>\n".utf8))
    exit(2)
}
exit(await ShimHost.run(directory: CommandLine.arguments[1]))
