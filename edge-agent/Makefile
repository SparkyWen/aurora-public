DIST ?= dist

# `make home` builds for this machine; override to cross-compile, for example
# `make home GOOS=linux GOARCH=arm64`. The relay agent drives nftables, so it only
# makes sense on Linux: `make relay RELAY_GOARCH=arm64` covers ARM servers.
GOOS ?= $(shell go env GOOS)
GOARCH ?= $(shell go env GOARCH)
RELAY_GOARCH ?= amd64

.PHONY: all test home relay

all: home relay

test:
	go test ./...
	go vet ./...

home:
	mkdir -p "$(DIST)"
	CGO_ENABLED=0 GOOS=$(GOOS) GOARCH=$(GOARCH) go build -trimpath -o "$(DIST)/aurora-home-agent" ./cmd/aurora-home-agent

relay:
	mkdir -p "$(DIST)"
	CGO_ENABLED=0 GOOS=linux GOARCH=$(RELAY_GOARCH) go build -trimpath -o "$(DIST)/aurora-relay-agent" ./cmd/aurora-relay-agent
