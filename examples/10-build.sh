#!/usr/bin/env bash
# docker build through buildx: BuildKit in its own VM, the image loaded into pratico.
. "$(dirname "$0")/lib.sh"
CTX=$(mktemp -d -t pratico-example-build)
trap 'rm -rf "$CTX"; docker rmi -f pratico-example-built >/dev/null 2>&1 || true' EXIT

step "the builder, once (loads every build into pratico)"
docker buildx inspect pratico-build >/dev/null 2>&1 ||
    docker buildx create --name pratico-build --driver docker-container --driver-opt default-load=true
export BUILDX_BUILDER=pratico-build

step "a multi-stage build: compile in one stage, ship only the binary"
cat >"$CTX/Dockerfile" <<'DOCKERFILE'
FROM golang:1.23-alpine AS build
WORKDIR /src
RUN printf 'package main\nimport "fmt"\nfunc main() { fmt.Println("hello from a pratico build") }\n' > main.go && go mod init example && CGO_ENABLED=0 go build -o /app .
FROM scratch
COPY --from=build /app /app
ENTRYPOINT ["/app"]
DOCKERFILE
docker build -q -t pratico-example-built "$CTX"

step "it runs, and it was scanned on arrival"
docker run --rm pratico-example-built
api /pratico/scans | python3 -c 'import json,sys; [print(i["Name"], i.get("Verdict", "scanning")) for i in json.load(sys.stdin) if "pratico-example-built" in i["Name"]]'
