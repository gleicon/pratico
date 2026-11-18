#!/bin/bash
# Runs inside the build container (scripts/build-init.sh): builds vminitd and vmexec from
# Vendor/containerization with Swift's static Linux SDK, then writes the init image as an
# OCI layout in /out/vminit, with fixed timestamps and owners so the bytes repeat.
set -euo pipefail
: "${SDK_SHA256:?}" "${IMAGE_REPO:?}" "${INIT_VERSION:?}" "${BUILD_TIME:?}" "${GIT_COMMIT:?}"

sdk=/sdk/static-sdk.artifactbundle.tar.gz  # downloaded and verified by the host
swift sdk list | grep -q static-linux || swift sdk install "$sdk" --checksum "$SDK_SHA256" >/dev/null

# Same paths every build: they are in the binaries' metadata.
rm -rf /build/src
cp -a /src /build/src
cd /build/src/vminitd
flags=(-c release --swift-sdk aarch64-swift-linux-musl -Xlinker -s -Xlinker --build-id=none --scratch-path /build/scratch)
export BUILD_TIME GIT_COMMIT
swift build "${flags[@]}" --quiet --product vminitd  # errors go to stdout: keep them
swift build "${flags[@]}" --quiet --product vmexec
bin=$(swift build "${flags[@]}" --show-bin-path)

root=/build/rootfs
rm -rf "$root" /build/layer.tar
# The tree upstream's vminit image has: vminitd mounts onto these, on a read-only root.
mkdir -p "$root"/{bin,dev,mnt,proc/self,run,sbin,sys,tmp,var}
chmod 0700 "$root"
install -m 0755 "$bin/vminitd" "$bin/vmexec" "$root/sbin/"
# Swift's per-module hashes (.swift_modhash) change from one build of the same source to
# the next, and only debuggers and the backtracer read them; these binaries carry no
# debug info, and neither a build ID, which would hash them.
for b in "$root/sbin/vminitd" "$root/sbin/vmexec"; do llvm-objcopy --remove-section=.swift_modhash "$b"; done
ln -s sbin/vminitd "$root/proc/self/exe"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C "$root" -cf /build/layer.tar .
diff_id=$(sha256sum /build/layer.tar | cut -d' ' -f1)
gzip -n -9 -c /build/layer.tar > /build/layer.tar.gz

out=/out/vminit
rm -rf "$out"
mkdir -p "$out/blobs/sha256"
blob() {  # file: stores it by digest, prints the digest
    local d
    d=$(sha256sum "$1" | cut -d' ' -f1)
    cp "$1" "$out/blobs/sha256/$d"
    echo "$d"
}
layer=$(blob /build/layer.tar.gz)
printf '{"architecture":"arm64","config":{"Labels":{"org.opencontainers.image.source":"https://github.com/gleicon/pratico"}},"os":"linux","rootfs":{"diff_ids":["sha256:%s"],"type":"layers"}}' "$diff_id" > /build/config.json
config=$(blob /build/config.json)
printf '{"config":{"digest":"sha256:%s","mediaType":"application/vnd.oci.image.config.v1+json","size":%d},"layers":[{"digest":"sha256:%s","mediaType":"application/vnd.oci.image.layer.v1.tar+gzip","size":%d}],"mediaType":"application/vnd.oci.image.manifest.v1+json","schemaVersion":2}' \
    "$config" "$(stat -c %s /build/config.json)" "$layer" "$(stat -c %s /build/layer.tar.gz)" > /build/manifest.json
manifest=$(blob /build/manifest.json)
# Tagged by content: the daemon rebuilds its init disk when the reference changes.
tag="$INIT_VERSION-${manifest:0:12}"
printf '{"imageLayoutVersion":"1.0.0"}' > "$out/oci-layout"
printf '{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:%s","size":%d,"platform":{"architecture":"arm64","os":"linux"},"annotations":{"org.opencontainers.image.ref.name":"%s","io.containerd.image.name":"%s"}}]}' \
    "$manifest" "$(stat -c %s /build/manifest.json)" "$tag" "$IMAGE_REPO:$tag" > "$out/index.json"
echo "init: vminitd $(stat -c %s "$root/sbin/vminitd") bytes, vmexec $(stat -c %s "$root/sbin/vmexec") bytes, $IMAGE_REPO:$tag"
