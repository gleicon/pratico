# Builds

`docker build`, `docker buildx build`, and `docker compose build` run BuildKit through
buildx's `docker-container` driver: BuildKit (`moby/buildkit`) runs in a container,
which on pratico is its own VM, and each result is loaded back into pratico, where it is
scanned like any image that arrives.

## Once

```sh
brew install docker-buildx   # the buildx plugin, if the docker CLI lacks it
docker buildx create --name pratico-build --driver docker-container --driver-opt default-load=true
echo 'export BUILDX_BUILDER=pratico-build' >> ~/.zshrc
```

The menubar's **Use with docker…** shows the same lines.

`default-load=true` loads every build into pratico without `--load`. `BUILDX_BUILDER` is
what makes a plain `docker build` use that builder: the docker CLI hands buildx the
builder named after the current docker context, which on a daemon without its own
BuildKit is an automatic `docker-container` builder that keeps results in its cache.
Without the variable, `docker build` succeeds and its image stays there (buildx says so:
"No output specified … Build result will only remain in the build cache").

## What works

- Dockerfiles with multi-stage builds, `RUN` with the network, `COPY --from`, cache
  mounts, secrets, and SSH forwarding: it is BuildKit.
- `docker compose build` and `up --build`: Compose asks for the image to be loaded, so
  it works with the automatic builder too.
- Rebuilds are cached in the builder's VM, which stays between builds; `docker buildx
  prune` empties its cache, and `docker buildx rm pratico-build` removes it.
- BuildKit runs privileged inside its VM, which is what it needs to build; the VM is
  the boundary, as for any container.

## Buildpacks

`pack build` works against pratico with no setup beyond `DOCKER_HOST`, checked with
pack 0.40 and `heroku/builder:24`, a first build and a cached rebuild:

```sh
pack build myapp --builder heroku/builder:24
docker run -p 8080:8080 myapp
```

pack runs the buildpacks' lifecycle in a container that reaches pratico through the
mounted Docker socket, keeps its caches in volumes, and loads the image into pratico,
where it is scanned like any image that arrives. Containers run on arm64, so the
builder must be published for it, as `heroku/builder:24` is.

## What does not

- The legacy builder (`DOCKER_BUILDKIT=0`, `POST /build`) is not served.
- A build pushes straight to a registry with `--push`, as BuildKit does; pratico's own
  store gets it through `--load` or `default-load`.

Decision: SPEC D-50. Example: [examples/10-build.sh](../examples/10-build.sh).
