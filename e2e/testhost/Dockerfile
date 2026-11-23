# The Linux test host (docs/design/remote.md): Ubuntu 24.04 as a VPS runs it, systemd and
# sshd, nothing from Docker (pratico answers `docker system dial-stdio` itself), and a user
# `dev` with sudo, who installs pratico from the
# release payload e2e/testhost.sh mounts at /opt/pratico. It boots as
# `--runtime pratico-testhost`, so /dev/kvm is there.
FROM ubuntu@sha256:9c7f200c07e3d4a03e7249d2c16bf66a51120fb876aa2242cf31451412543289
ENV container=docker
RUN apt-get -qq update && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends \
        ca-certificates curl dbus netcat-openbsd openssh-server python3 sudo systemd systemd-sysv >/dev/null \
    && rm -rf /var/lib/apt/lists/* \
    && systemctl enable ssh.service >/dev/null 2>&1 \
    && useradd -m -s /bin/bash dev && echo 'dev ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/dev \
    && mkdir -p /root/.ssh /home/dev/.ssh && chmod 700 /root/.ssh /home/dev/.ssh && chown dev:dev /home/dev/.ssh \
    && groupadd -r kvm \
    && printf 'PasswordAuthentication no\nPermitRootLogin prohibit-password\n' >/etc/ssh/sshd_config.d/pratico.conf
COPY entrypoint.sh /entrypoint.sh
EXPOSE 22
STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/entrypoint.sh"]
