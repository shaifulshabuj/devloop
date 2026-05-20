.PHONY: tui tui-install tui-dev tui-clean tui-test
.PHONY: build test lint install clean

# ── v6 targets ─────────────────────────────────────────────────────────────

BINARY := devloop
VERSION := v6.1.2
LDFLAGS := -ldflags "-X main.version=$(VERSION)"

build:
	go build $(LDFLAGS) -o $(BINARY) ./cmd/devloop

test:
	go test ./... -race -count=1

lint:
	golangci-lint run ./...

install:
	go install $(LDFLAGS) ./cmd/devloop

clean:
	rm -f $(BINARY)

# ── legacy v5 TUI targets ───────────────────────────────────────────────────

tui:
	$(MAKE) -C cmd/devloop-tui build

tui-install:
	$(MAKE) -C cmd/devloop-tui install

tui-dev:
	$(MAKE) -C cmd/devloop-tui dev

tui-clean:
	$(MAKE) -C cmd/devloop-tui clean

tui-test:
	$(MAKE) -C cmd/devloop-tui test
