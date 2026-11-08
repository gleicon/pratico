Pratico — Docker API for Apple's container runtime
===================================================

Install
  1. Drag Pratico.app onto the Applications folder in this window.
  2. Install Apple's `container` runtime if you have not, and run
     `container system start` once.

First launch (Gatekeeper)
  Pratico is ad-hoc signed, not notarized, so macOS blocks the first launch.
  Approve it once, either way:

  a) Open Pratico.app. When macOS refuses, open System Settings >
     Privacy & Security, scroll to the message about Pratico, and click
     "Open Anyway". Confirm in the dialog that follows.

  b) Or, in Terminal:
       xattr -dr com.apple.quarantine /Applications/Pratico.app

  Then approve the background item if macOS asks
  (System Settings > General > Login Items).

Use
  Pratico lives in the menu bar. Point the docker CLI at it:
    export DOCKER_HOST=unix://$HOME/.pratico/docker.sock
    docker run --rm alpine echo hello
