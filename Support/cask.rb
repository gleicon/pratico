cask "pratico" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/gleicon/pratico/releases/download/v#{version}/Pratico-#{version}.dmg"
  name "Pratico"
  desc "Local container manager: each container in its own VM, Docker-compatible API"
  homepage "https://github.com/gleicon/pratico"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Pratico.app"

  # The optional boot job that links /var/run/docker.sock; the link itself is left alone,
  # since it may be another tool's, and macOS empties /var/run at boot.
  uninstall launchctl: [
              "dev.pratico.daemon",
              "dev.pratico.socket",
            ],
            quit:      "dev.pratico.menubar",
            delete:    "/Library/LaunchDaemons/dev.pratico.socket.plist"

  # Containers, images, and volumes live in ~/.pratico: --zap deletes them.
  zap trash: [
    "~/.pratico",
    "~/Library/LaunchAgents/dev.pratico.daemon.plist",
  ]

  caveats <<~EOS
    Pratico is not notarized by Apple yet: approve its first launch once in
    System Settings > Privacy & Security ("Open Anyway").

    `brew uninstall --zap pratico` also deletes ~/.pratico: every container,
    image, and volume.
  EOS
end
