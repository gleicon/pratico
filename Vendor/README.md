# Vendored code

## containerization

`containerization/` is [apple/containerization](https://github.com/apple/containerization)
(Apache-2.0) at tag `0.54.0`, commit `baf212e5a8e432e539beee325050aa26443a154d`, added
with `git subtree --squash`. It holds the host Swift package pratico links (VMs,
images, EXT4, the agent's client) and the guest init that runs in every VM (`vminitd/`:
`vminitd` and `vmexec`). Both are kept at one commit, as they speak one agent protocol.

pratico changes it for its own VM (roadmap: "Own VM, self-contained"): each changed
file says so in its header, as Apache-2.0 asks, and the changes are listed here.
Upstream fixes are merged with:

```sh
git subtree pull --prefix Vendor/containerization https://github.com/apple/containerization.git <tag> --squash
```

### Changes

None yet: the tree is upstream's.
