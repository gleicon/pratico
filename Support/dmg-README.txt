Pratico: local containers, one small VM per container
=====================================================

1. Install
   Drag Pratico onto the Applications folder in this window.

2. Approve the first launch (once)
   Pratico is not notarized by Apple yet, so macOS stops its first launch.
   Use either way.

   Without Terminal
     a. Open Pratico from Applications. macOS says it cannot check it:
        click Done.
     b. Open System Settings > Privacy & Security and scroll down to
        Security: "Pratico was blocked to protect your Mac".
     c. Click Open Anyway, enter your password, then click Open Anyway
        in the dialog that follows.

   With Terminal, before you open this disk image
     Eject it, then remove the download's quarantine and open it again:
       xattr -d com.apple.quarantine ~/Downloads/Pratico-*.dmg
     Pratico copied from it then opens without a prompt.

     If Pratico is already in Applications, this does the same:
       xattr -dr com.apple.quarantine /Applications/Pratico.app
     If it answers "Operation not permitted", macOS is protecting the app
     folder from Terminal: use the way without Terminal, or allow Terminal
     under Privacy & Security > App Management.

3. Use
   Pratico lives in the menu bar; it starts its daemon, and macOS may say it
   added a background item: that is the daemon, which keeps containers
   running when the menu bar app quits.
   Point your Docker client at its socket:
     docker context create pratico --docker host=unix://$HOME/.pratico/docker.sock
     docker context use pratico
     docker run --rm alpine echo hello

Licenses
  Acknowledgements.txt lists Pratico's license and those of what it ships,
  with the source offer for the Linux kernel.
