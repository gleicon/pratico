#!/bin/sh
# Starts the test host: sshd for the Mac's docker CLI, and pratico's daemon on the socket
# the docker CLI looks for by default.
set -eu
install -m 600 /opt/pratico/authorized_keys /root/.ssh/authorized_keys
ssh-keygen -A >/dev/null
/usr/sbin/sshd
export PATH="/opt/pratico:$PATH"
mkdir -p /root/.pratico
ln -sf /root/.pratico/docker.sock /var/run/docker.sock
exec env PRATICO_RUNTIME_ASSETS=/opt/pratico/runtime /opt/pratico/pratico-daemon --home /root/.pratico
