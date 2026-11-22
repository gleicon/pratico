#!/bin/sh
# Starts the test host: this run's key for root and dev, /dev/kvm and /dev/net/tun as
# Ubuntu's udev rules leave them (kvm: group kvm, 0660; tun: 0666; the image's kvm group
# is the one udev's package creates), then systemd. pratico is installed over ssh, by dev.
set -eu
for u in root dev; do
    h=$(getent passwd "$u" | cut -d: -f6)
    install -m 600 -o "$u" -g "$u" /opt/pratico/authorized_keys "$h/.ssh/authorized_keys"
done
chgrp kvm /dev/kvm && chmod 660 /dev/kvm && chmod 666 /dev/net/tun
exec /sbin/init
