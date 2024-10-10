# syntax = docker/dockerfile-upstream:1.10.0-labs

# THIS FILE WAS AUTOMATICALLY GENERATED, PLEASE DO NOT EDIT.
#
# Generated on 2024-10-10T13:37:23Z by kres 34e72ac.

ARG TOOLCHAIN

FROM alpine:3.20 AS base-image-release-tool

# cleaned up specs and compiled versions
FROM scratch AS generate

# runs markdownlint
FROM docker.io/oven/bun:1.1.29-alpine AS lint-markdown
WORKDIR /src
RUN bun i markdownlint-cli@0.41.0 sentences-per-line@0.2.1
COPY .markdownlint.json .
COPY ./README.md ./README.md
RUN bunx markdownlint --ignore "CHANGELOG.md" --ignore "**/node_modules/**" --ignore '**/hack/chglog/**' --rules node_modules/sentences-per-line/index.js .

# base toolchain image
FROM --platform=${BUILDPLATFORM} ${TOOLCHAIN} AS toolchain
RUN apk --update --no-cache add bash curl build-base protoc protobuf-dev

# build tools
FROM --platform=${BUILDPLATFORM} toolchain AS tools
ENV GO111MODULE=on
ARG CGO_ENABLED
ENV CGO_ENABLED=${CGO_ENABLED}
ARG GOTOOLCHAIN
ENV GOTOOLCHAIN=${GOTOOLCHAIN}
ARG GOEXPERIMENT
ENV GOEXPERIMENT=${GOEXPERIMENT}
ENV GOPATH=/go
ARG DEEPCOPY_VERSION
RUN --mount=type=cache,target=/root/.cache/go-build --mount=type=cache,target=/go/pkg go install github.com/siderolabs/deep-copy@${DEEPCOPY_VERSION} \
	&& mv /go/bin/deep-copy /bin/deep-copy
ARG GOLANGCILINT_VERSION
RUN --mount=type=cache,target=/root/.cache/go-build --mount=type=cache,target=/go/pkg go install github.com/golangci/golangci-lint/cmd/golangci-lint@${GOLANGCILINT_VERSION} \
	&& mv /go/bin/golangci-lint /bin/golangci-lint
RUN --mount=type=cache,target=/root/.cache/go-build --mount=type=cache,target=/go/pkg go install golang.org/x/vuln/cmd/govulncheck@latest \
	&& mv /go/bin/govulncheck /bin/govulncheck
ARG GOFUMPT_VERSION
RUN go install mvdan.cc/gofumpt@${GOFUMPT_VERSION} \
	&& mv /go/bin/gofumpt /bin/gofumpt

# tools and sources
FROM tools AS base
WORKDIR /src
COPY go.mod go.mod
COPY go.sum go.sum
RUN cd .
RUN --mount=type=cache,target=/go/pkg go mod download
RUN --mount=type=cache,target=/go/pkg go mod verify
COPY ./cmd ./cmd
RUN --mount=type=cache,target=/go/pkg go list -mod=readonly all >/dev/null

# runs gofumpt
FROM base AS lint-gofumpt
RUN FILES="$(gofumpt -l .)" && test -z "${FILES}" || (echo -e "Source code is not formatted with 'gofumpt -w .':\n${FILES}"; exit 1)

# runs golangci-lint
FROM base AS lint-golangci-lint
WORKDIR /src
COPY .golangci.yml .
ENV GOGC=50
RUN golangci-lint config verify --config .golangci.yml
RUN --mount=type=cache,target=/root/.cache/go-build --mount=type=cache,target=/root/.cache/golangci-lint --mount=type=cache,target=/go/pkg golangci-lint run --config .golangci.yml

# runs govulncheck
FROM base AS lint-govulncheck
WORKDIR /src
RUN --mount=type=cache,target=/root/.cache/go-build --mount=type=cache,target=/go/pkg govulncheck ./...

# builds release-tool-linux-amd64
FROM base AS release-tool-linux-amd64-build
COPY --from=generate / /
WORKDIR /src/cmd/release-tool
ARG GO_BUILDFLAGS
ARG GO_LDFLAGS
RUN --mount=type=cache,target=/root/.cache/go-build --mount=type=cache,target=/go/pkg go build ${GO_BUILDFLAGS} -ldflags "${GO_LDFLAGS}" -o /release-tool-linux-amd64

# runs unit-tests with race detector
FROM base AS unit-tests-race
WORKDIR /src
ARG TESTPKGS
RUN --mount=type=cache,target=/root/.cache/go-build --mount=type=cache,target=/go/pkg --mount=type=cache,target=/tmp CGO_ENABLED=1 go test -v -race -count 1 ${TESTPKGS}

# runs unit-tests
FROM base AS unit-tests-run
WORKDIR /src
ARG TESTPKGS
RUN --mount=type=cache,target=/root/.cache/go-build --mount=type=cache,target=/go/pkg --mount=type=cache,target=/tmp go test -v -covermode=atomic -coverprofile=coverage.txt -coverpkg=${TESTPKGS} -count 1 ${TESTPKGS}

FROM scratch AS release-tool-linux-amd64
COPY --from=release-tool-linux-amd64-build /release-tool-linux-amd64 /release-tool-linux-amd64

FROM scratch AS unit-tests
COPY --from=unit-tests-run /src/coverage.txt /coverage-unit-tests.txt

FROM release-tool-linux-${TARGETARCH} AS release-tool

FROM scratch AS release-tool-all
COPY --from=release-tool-linux-amd64 / /

FROM base-image-release-tool AS image-release-tool
RUN apk add --no-cache git git-lfs make sed
ARG TARGETARCH
COPY --from=release-tool release-tool-linux-${TARGETARCH} /release-tool
LABEL org.opencontainers.image.source=https://github.com/siderolabs/release-tool
ENTRYPOINT ["/release-tool"]

