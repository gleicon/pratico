# The Linux test host (docs/design/remote.md): Ubuntu 24.04, as a VPS runs it, with sshd
# and the docker CLI (`docker -H ssh://` runs `docker system dial-stdio` here). pratico's
# Linux daemon, shim, runtime assets and Cloud Hypervisor are mounted at /opt/pratico by
# e2e/testhost.sh; it boots as `--runtime pratico-testhost`, so /dev/kvm is there.
FROM ubuntu@sha256:9c7f200c07e3d4a03e7249d2c16bf66a51120fb876aa2242cf31451412543289
RUN apt-get -qq update && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends \
        ca-certificates docker.io libarchive13t64 libcurl4t64 libbz2-1.0 liblzma5 libssl3t64 openssh-server >/dev/null \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh \
    && printf 'PasswordAuthentication no\nPermitRootLogin prohibit-password\n' >/etc/ssh/sshd_config.d/pratico.conf
COPY entrypoint.sh /entrypoint.sh
EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
