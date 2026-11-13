Pratico — Docker on your Mac, one small VM per container
=======================================================

Install
  Drag Pratico.app onto the Applications folder in this window. Nothing else
  needs installing: Pratico carries the Linux kernel it runs containers on.

First launch (Gatekeeper)
  Pratico is ad-hoc signed, not notarized, so macOS blocks the first launch.
  Approve it once, either way:

  a) Open Pratico.app. When macOS refuses, open System Settings >
     Privacy & Security, scroll to the message about Pratico, and click
     "Open Anyway". Confirm in the dialog that follows.

  b) Or, in Terminal:
       xattr -dr com.apple.quarantine /Applications/Pratico.app

  macOS may say that Pratico added a background item: that is its daemon,
  which keeps containers running when the menu bar app quits.

Use
  Pratico lives in the menu bar. Point the docker CLI at it:
    export DOCKER_HOST=unix://$HOME/.pratico/docker.sock
    docker run --rm alpine echo hello

Licenses
  Acknowledgements.txt lists Pratico's license and those of what it ships.
